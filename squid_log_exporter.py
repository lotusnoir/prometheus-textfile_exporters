#!/usr/bin/env python3
"""
Squid access.log -> Prometheus textfile exporter.

- Per-rule counters always present (seeded at 0 from /etc/squid/conf.d/notes.conf),
  so a rule with zero traffic still shows up in Prometheus.
- Standard request/byte/peer counters per rule.
- Extra breakdown for TCP_DENIED and for any 5xx status: per rule/client_ip/destination/http_status,
  so you can see exactly who got denied / who hit a 503 and against which destination.
- Full-URL tracking for selected rules (global_domain, global_ips): every URL seen
  through these rules is recorded as its own time series.
- last_seen gauge for every domain declared under /etc/squid/conf.d/destinations/*,
  so you can spot domains that are configured but never (or no longer) used.
"""
import json, os, re, sys, tempfile, time
from urllib.parse import urlsplit

LOG_FILE = os.environ.get("SQUID_LOG_EXPORTER_LOG_FILE", "/var/log/squid/access.log")
STATE_FILE = os.environ.get("SQUID_LOG_EXPORTER_STATE_FILE", "/var/lib/squid-prom-exporter/state.json")
OUT_FILE = os.environ.get("SQUID_LOG_EXPORTER_OUT_FILE", "/var/lib/node_exporter/squid_log.prom")
NOTES_CONF = os.environ.get("SQUID_LOG_EXPORTER_NOTES_CONF", "/etc/squid/conf.d/notes.conf")
DESTINATIONS_DIR = os.environ.get("SQUID_LOG_EXPORTER_DESTINATIONS_DIR", "/etc/squid/conf.d/destinations")
OUT_FILE_MODE = int(os.environ.get("SQUID_LOG_EXPORTER_OUT_FILE_MODE", "0o644"), 8)

# Rules for which every individual URL seen must be recorded as its own series.
URL_LOGGED_RULES = {"global_domain", "global_ips"}

# TTL (in seconds) for high-cardinality counters (denied / 5xx / url_seen, keyed by
# client_ip+url). Entries not seen again within this window are purged so the
# state file / .prom file don't grow forever with one-off clients/URLs.
# Default: 1 day. NOTE: domain_last_seen is intentionally NOT in this set -
# it tracks a finite, config-driven list of domains and must persist even with 0 traffic.
HIGH_CARDINALITY_METRICS = ("denied", "status5xx", "url_seen")
TTL_SECONDS = int(os.environ.get("SQUID_LOG_EXPORTER_TTL_SECONDS", str(1 * 24 * 3600)))


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"inode": None, "offset": 0, "counters": {}, "parse_errors": 0}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def bump(counters, key, n=1):
    counters[key] = counters.get(key, 0) + n


def bump_tracked(counters, last_seen, key, now, n=1):
    counters[key] = counters.get(key, 0) + n
    last_seen[key] = now


def set_gauge(counters, key, value):
    counters[key] = value


def purge_expired(counters, last_seen, now, ttl):
    """Drop high-cardinality counters (denied/5xx/url_seen) not refreshed within ttl seconds."""
    expired = [
        key for key in list(counters.keys())
        if key.split("|", 1)[0] in HIGH_CARDINALITY_METRICS
        and now - last_seen.get(key, now) > ttl
    ]
    for key in expired:
        counters.pop(key, None)
        last_seen.pop(key, None)
    return len(expired)


def load_known_rules():
    """Extract every rule name declared in notes.conf (note rule_matched ...)."""
    rules = set()
    try:
        with open(NOTES_CONF) as f:
            for line in f:
                line = line.strip()
                if not line.startswith("note rule_matched"):
                    continue
                parts = line.split()
                # "note rule_matched <value>"                 -> catch-all line (3 tokens)
                # "note rule_matched <key> <value> <acl...>"   -> normal line (>=4 tokens)
                if len(parts) >= 3:
                    rules.add(parts[2])
    except FileNotFoundError:
        pass
    return rules


def seed_rules(counters, rules):
    """Make sure every known rule has at least a 0 request counter, even with no traffic."""
    for rule in rules:
        labels = f'rule="{rule}"'
        counters.setdefault(f"rule_requests|{labels}", 0)


def load_known_destinations(base_dir=DESTINATIONS_DIR):
    """
    Walk /etc/squid/conf.d/destinations/{global,groups,hosts,...} and extract every
    domain listed (one domain per line, '#' starts a comment, blank lines skipped).
    Returns: dict domain -> {"category": <top-level subdir>, "file": <relative path>}
    """
    destinations = {}
    if not os.path.isdir(base_dir):
        return destinations
    for root, _dirs, files in os.walk(base_dir):
        for fname in files:
            fpath = os.path.join(root, fname)
            rel_path = os.path.relpath(fpath, base_dir)
            category = rel_path.split(os.sep)[0]
            try:
                with open(fpath, errors="replace") as f:
                    for line in f:
                        line = line.split("#", 1)[0].strip()
                        if not line:
                            continue
                        domain = line.split()[0]
                        destinations[domain] = {"category": category, "file": rel_path}
            except OSError:
                continue
    return destinations


def build_destination_matcher(destinations):
    """
    Split known domains into:
      - exact: dict host -> (domain_label, info)       for plain entries ("example.com")
      - suffix: list of (base, domain_label, info)      for wildcard entries (".example.com")
    Squid semantics: ".example.com" matches "example.com" AND any subdomain of it.
    """
    exact = {}
    suffix = []
    for domain, info in destinations.items():
        if domain.startswith("."):
            suffix.append((domain[1:], domain, info))
        else:
            exact[domain] = (domain, info)
    return exact, suffix


def match_destination(host, exact, suffix):
    if not host or host == "unknown":
        return None
    if host in exact:
        return exact[host]
    for base, original, info in suffix:
        if host == base or host.endswith("." + base):
            return (original, info)
    return None


def seed_destinations(counters, destinations):
    """Make sure every configured domain has a last_seen series, even at 0 (never seen)."""
    for domain, info in destinations.items():
        key = f'dest_last_seen|domain="{sanitize_label(domain)}",category="{sanitize_label(info["category"])}"'
        counters.setdefault(key, 0)


def extract_destination(url, method):
    """Return a bare hostname (no port, no path) from the request-URI."""
    if not url or url == "-":
        return "unknown"
    if method == "CONNECT":
        # format is host:port
        host = url.rsplit(":", 1)[0]
        return host or "unknown"
    try:
        parsed = urlsplit(url if "://" in url else f"//{url}")
        host = parsed.hostname
        return host or "unknown"
    except ValueError:
        return "unknown"


def sanitize_label(value):
    # Escape characters that would break Prometheus exposition format
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "")


def parse_line(line, counters, last_seen, now, dest_exact, dest_suffix):
    parts = line.split()
    # Expected fixed squid logformat with rule_matched note appended:
    # 0:ts 1:elapsed_ms 2:client_ip 3:code/status 4:bytes 5:method 6:url
    # 7:rfc931 8:hier/peer 9:mime_type 10:rule
    if len(parts) < 11:
        return False

    try:
        client_ip = parts[2]
        code_field = parts[3]
        nbytes = int(parts[4])
        method = parts[5]
        url = parts[6]
        hier_field = parts[8]
    except (ValueError, IndexError):
        return False

    rule = sanitize_label(parts[-1]) or "unknown"

    cache_result, _, http_status = code_field.partition("/")
    http_status = http_status or "000"
    status_class = f"{http_status[0]}xx" if http_status.isdigit() and len(http_status) == 3 else "unknown"

    peer = hier_field.split("/")[0] if "/" in hier_field else hier_field
    raw_destination = extract_destination(url, method)
    destination = sanitize_label(raw_destination)
    client_ip = sanitize_label(client_ip)
    cache_result = sanitize_label(cache_result)
    method = sanitize_label(method)

    # --- standard metrics ---
    labels_req = (
        f'rule="{rule}",cache_result="{cache_result}",http_status="{http_status}",'
        f'status_class="{status_class}",method="{method}"'
    )
    bump(counters, f"requests|{labels_req}")

    labels_bytes = f'rule="{rule}",cache_result="{cache_result}"'
    bump(counters, f"bytes|{labels_bytes}", nbytes)

    labels_rule = f'rule="{rule}"'
    bump(counters, f"rule_requests|{labels_rule}")

    labels_peer = f'rule="{rule}",peer="{peer}"'
    bump(counters, f"peer|{labels_peer}")

    # --- DENIED breakdown (source/destination) ---
    if cache_result == "TCP_DENIED" or "DENIED" in cache_result:
        full_url = sanitize_label(url)
        labels_denied = (
            f'rule="{rule}",client_ip="{client_ip}",destination="{destination}",url="{full_url}",'
            f'http_status="{http_status}",method="{method}"'
        )
        bump_tracked(counters, last_seen, f"denied|{labels_denied}", now)

    # --- any 5xx breakdown (covers 503 etc.) with source/destination ---
    if status_class == "5xx":
        full_url = sanitize_label(url)
        labels_5xx = (
            f'rule="{rule}",client_ip="{client_ip}",destination="{destination}",url="{full_url}",'
            f'http_status="{http_status}",cache_result="{cache_result}",method="{method}"'
        )
        bump_tracked(counters, last_seen, f"status5xx|{labels_5xx}", now)

    # --- full URL tracking for selected rules ---
    if rule in URL_LOGGED_RULES:
        full_url = sanitize_label(url)
        labels_url = (
            f'rule="{rule}",client_ip="{client_ip}",destination="{destination}",'
            f'http_status="{http_status}",method="{method}",url="{full_url}"'
        )
        bump_tracked(counters, last_seen, f"url_seen|{labels_url}", now)

    # --- last_seen for configured destination domains ---
    match = match_destination(raw_destination, dest_exact, dest_suffix)
    if match:
        domain_label, info = match
        key = (
            f'dest_last_seen|domain="{sanitize_label(domain_label)}",'
            f'category="{sanitize_label(info["category"])}"'
        )
        set_gauge(counters, key, now)

    return True


def main():
    state = load_state()
    counters = state.get("counters", {})
    last_seen = state.get("last_seen", {})
    parse_errors = state.get("parse_errors", 0)

    seed_rules(counters, load_known_rules())

    destinations = load_known_destinations()
    dest_exact, dest_suffix = build_destination_matcher(destinations)
    seed_destinations(counters, destinations)

    now = time.time()
    purged = purge_expired(counters, last_seen, now, TTL_SECONDS)

    try:
        st = os.stat(LOG_FILE)
    except FileNotFoundError:
        sys.exit(f"log file not found: {LOG_FILE}")

    inode = st.st_ino
    offset = state.get("offset", 0)

    if state.get("inode") != inode or st.st_size < offset:
        offset = 0

    with open(LOG_FILE, "r", errors="replace") as f:
        f.seek(offset)
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if not parse_line(line, counters, last_seen, now, dest_exact, dest_suffix):
                parse_errors += 1
        new_offset = f.tell()

    state = {
        "inode": inode,
        "offset": new_offset,
        "counters": counters,
        "last_seen": last_seen,
        "parse_errors": parse_errors,
    }
    save_state(state)

    write_metrics(counters, parse_errors, purged)


def write_metrics(counters, parse_errors, purged=0):
    lines = []

    def header(name, help_text, mtype="counter"):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {mtype}")

    header("squid_log_requests_total", "Total requests seen in access.log by rule/result/status")
    header("squid_log_response_bytes_total", "Total bytes by rule/result")
    header("squid_log_rule_requests_total", "Total requests by rule (regardless of result/status)")
    header("squid_log_peer_requests_total", "Requests by rule and hierarchy peer")
    header("squid_log_denied_requests_total", "TCP_DENIED requests by rule/client_ip/destination/http_status")
    header("squid_log_5xx_requests_total", "5xx requests (e.g. 503) by rule/client_ip/destination/http_status/cache_result")
    header("squid_log_url_requests_total", "Requests seen per URL for selected rules (global_domain, global_ips)")
    header(
        "squid_log_destination_last_seen_seconds",
        "Unix timestamp of the last time a configured destination domain "
        "(/etc/squid/conf.d/destinations/<category>/...) was seen in a request; 0 if never seen",
        mtype="gauge",
    )

    for key, value in counters.items():
        metric, labels = key.split("|", 1)
        if metric == "requests":
            lines.append(f"squid_log_requests_total{{{labels}}} {value}")
        elif metric == "bytes":
            lines.append(f"squid_log_response_bytes_total{{{labels}}} {value}")
        elif metric == "rule_requests":
            lines.append(f"squid_log_rule_requests_total{{{labels}}} {value}")
        elif metric == "peer":
            lines.append(f"squid_log_peer_requests_total{{{labels}}} {value}")
        elif metric == "denied":
            lines.append(f"squid_log_denied_requests_total{{{labels}}} {value}")
        elif metric == "status5xx":
            lines.append(f"squid_log_5xx_requests_total{{{labels}}} {value}")
        elif metric == "url_seen":
            lines.append(f"squid_log_url_requests_total{{{labels}}} {value}")
        elif metric == "dest_last_seen":
            lines.append(f"squid_log_destination_last_seen_seconds{{{labels}}} {value}")

    header("squid_log_exporter_parse_errors_total", "Lines that could not be parsed")
    lines.append(f"squid_log_exporter_parse_errors_total {parse_errors}")

    header("squid_log_exporter_purged_series_total", "High-cardinality (denied/5xx/url_seen) series purged on this run due to TTL expiry", mtype="gauge")
    lines.append(f"squid_log_exporter_purged_series_total {purged}")

    header("squid_log_exporter_last_run_seconds", "Last successful run timestamp", mtype="gauge")
    lines.append(f"squid_log_exporter_last_run_seconds {time.time()}")

    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(OUT_FILE))
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp_path, OUT_FILE_MODE)
    os.replace(tmp_path, OUT_FILE)


if __name__ == "__main__":
    main()
