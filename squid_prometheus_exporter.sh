#!/bin/bash
# Exporte les stats Squid (destination x port x domaine x sous-domaine x client)
# au format Prometheus (texte expose sur STDOUT)
# Compatible awk POSIX (pas besoin de gawk)
#
# Metriques exposees (uniquement) : squid_connect_total / squid_miss_total / squid_denied_total
#   - Classification MUTUELLEMENT EXCLUSIVE par ligne de log :
#       1) DENIED  -> comptee uniquement en denied (meme si method == CONNECT)
#       2) MISS    -> comptee uniquement en miss
#       3) CONNECT -> comptee en connect
#   - Les series a valeur 0 ne sont PAS ecrites
#
#   - Labels : destination (host SANS le port) / port / domain / subdomain / client
#
#       squid_denied_total{destination="20.111.92.1",port="9350",
#                           domain="20.111.92.1",subdomain="20.111.92.1",
#                           client="vm-xxxxxxx-prod-01"} 1
#
#   - CLIENT : resolution DNS inverse (getent hosts), on ne garde QUE le
#     premier label du hostname resolu (pas l'extension de domaine).
#     Si la resolution echoue -> on garde l'IP brute en fallback.
#     Controlee par RESOLVE_CLIENT_DNS (true/false).
#
#     ATTENTION PERF : la resolution DNS se fait une fois par IP CLIENTE
#     UNIQUE (pas par ligne de log), avec un timeout de 1s par lookup.
#     Sur un gros volume de clients distincts, cela peut ralentir
#     l'execution du script de quelques secondes a quelques dizaines de
#     secondes. Desactivez (RESOLVE_CLIENT_DNS=false) si trop lent.
#
#     Limitation connue (domain/subdomain) : ne gere pas les TLD composes
#     (.co.uk, .com.br...). Pour une IP brute, domain == subdomain == destination.
#
# Usage :
#   ./squid_prometheus_exporter.sh                          # affiche sur stdout
#   ./squid_prometheus_exporter.sh > squid_stats.prom        # vers un fichier

LOGFILE="/var/log/squid/access.log"

# Motifs a exclure de l'analyse (bruit connu / domaines et sous-reseaux internes)
EXCLUDE_PATTERN=""

# "ip" = 1 serie par IP client (necessaire pour la resolution DNS)
# "subnet" = regroupement par /24 (desactive de facto la resolution DNS)
CLIENT_LABEL_MODE="ip"

# Resolution DNS inverse des IP clientes (true/false)
RESOLVE_CLIENT_DNS="true"

if [ ! -f "$LOGFILE" ]; then
    echo "Fichier introuvable: $LOGFILE" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

grep -Ev "$EXCLUDE_PATTERN" "$LOGFILE" > "$TMPDIR/filtered.log"

# ---------------------------------------------------------------------------
# Resolution DNS inverse des clients (une fois par IP unique)
# ---------------------------------------------------------------------------
CLIENT_MAP="$TMPDIR/client_map.tsv"
: > "$CLIENT_MAP"

if [ "$RESOLVE_CLIENT_DNS" = "true" ] && [ "$CLIENT_LABEL_MODE" = "ip" ]; then
    awk '{print $3}' "$TMPDIR/filtered.log" | sort -u > "$TMPDIR/clients_unique.txt"
    while read -r ip; do
        [ -z "$ip" ] && continue
        fqdn=$(timeout 1 getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -n1)
        if [ -n "$fqdn" ]; then
            short=$(echo "$fqdn" | cut -d. -f1)
            printf "%s\t%s\n" "$ip" "$short" >> "$CLIENT_MAP"
        else
            printf "%s\t%s\n" "$ip" "$ip" >> "$CLIENT_MAP"
        fi
    done < "$TMPDIR/clients_unique.txt"
fi

# ---------------------------------------------------------------------------
# Calcul des compteurs
# ---------------------------------------------------------------------------
awk -v client_mode="$CLIENT_LABEL_MODE" -v resolve_dns="$RESOLVE_CLIENT_DNS" -v client_map_file="$CLIENT_MAP" '
BEGIN {
    if (resolve_dns == "true" && client_map_file != "") {
        while ((getline line < client_map_file) > 0) {
            split(line, kv, "\t")
            client_map[kv[1]] = kv[2]
        }
        close(client_map_file)
    }
}
function split_host_port(dest, out,    idx, rest, slash_pos, colon_idx) {
    if (dest ~ /^https?:\/\//) {
        idx = index(dest, "://")
        rest = substr(dest, idx + 3)
        slash_pos = index(rest, "/")
        if (slash_pos > 0) rest = substr(rest, 1, slash_pos - 1)
        colon_idx = index(rest, ":")
        if (colon_idx > 0) { out["host"] = substr(rest, 1, colon_idx - 1); out["port"] = substr(rest, colon_idx + 1) }
        else { out["host"] = rest; out["port"] = "" }
    } else {
        colon_idx = index(dest, ":")
        if (colon_idx > 0) { out["host"] = substr(dest, 1, colon_idx - 1); out["port"] = substr(dest, colon_idx + 1) }
        else { out["host"] = dest; out["port"] = "" }
    }
}
function compute_domain(host,    n, a) {
    if (host ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return host
    n = split(host, a, ".")
    if (n >= 2) return a[n-1] "." a[n]
    return host
}
function compute_subdomain(host,    n, a) {
    if (host ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return host
    n = split(host, a, ".")
    if (n >= 3) return a[n-2] "." a[n-1] "." a[n]
    if (n >= 2) return a[n-1] "." a[n]
    return host
}
function client_label(ip,   a, n) {
    if (resolve_dns == "true" && client_mode == "ip") {
        if (ip in client_map) return client_map[ip]
        return ip
    }
    if (client_mode != "subnet") return ip
    n = split(ip, a, ".")
    if (n == 4) return a[1] "." a[2] "." a[3] ".0/24"
    return ip
}
{
    ip = $3
    status_field = $4
    method = $6
    split_host_port($7, hp)
    host = hp["host"]
    port = hp["port"]
    dom = compute_domain(host)
    subdom = compute_subdomain(host)

    split(status_field, s, "/")
    tag = s[1]

    cli = client_label(ip)
    key = host SUBSEP port SUBSEP cli

    if (tag ~ /DENIED/) {
        denied_count[key]++
    } else if (tag ~ /MISS/) {
        miss_count[key]++
    } else if (method == "CONNECT") {
        connect_count[key]++
    }

    domain_of[key] = dom
    subdomain_of[key] = subdom
    all_keys[key] = 1
}
END {
    for (key in all_keys) {
        split(key, parts, SUBSEP)
        d = parts[1]; p = parts[2]; c = parts[3]
        printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n", d, p, domain_of[key], subdomain_of[key], c, connect_count[key]+0, miss_count[key]+0, denied_count[key]+0
    }
}
' "$TMPDIR/filtered.log" > "$TMPDIR/data.tsv"

echo "# HELP squid_connect_total Nombre de requetes CONNECT abouties (tunnel HTTPS) par destination/port/domaine/sous-domaine/client"
echo "# TYPE squid_connect_total counter"
awk -F'\t' '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
$6 > 0 { printf "squid_connect_total{destination=\"%s\",port=\"%s\",domain=\"%s\",subdomain=\"%s\",client=\"%s\"} %d\n", esc($1), esc($2), esc($3), esc($4), esc($5), $6 }
' "$TMPDIR/data.tsv"

echo "# HELP squid_miss_total Nombre de requetes TCP_MISS* par destination/port/domaine/sous-domaine/client"
echo "# TYPE squid_miss_total counter"
awk -F'\t' '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
$7 > 0 { printf "squid_miss_total{destination=\"%s\",port=\"%s\",domain=\"%s\",subdomain=\"%s\",client=\"%s\"} %d\n", esc($1), esc($2), esc($3), esc($4), esc($5), $7 }
' "$TMPDIR/data.tsv"

echo "# HELP squid_denied_total Nombre de requetes TCP_DENIED* par destination/port/domaine/sous-domaine/client"
echo "# TYPE squid_denied_total counter"
awk -F'\t' '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
$8 > 0 { printf "squid_denied_total{destination=\"%s\",port=\"%s\",domain=\"%s\",subdomain=\"%s\",client=\"%s\"} %d\n", esc($1), esc($2), esc($3), esc($4), esc($5), $8 }
' "$TMPDIR/data.tsv"

echo "# HELP squid_textfile_last_run_timestamp_seconds Horodatage de la derniere generation de ce fichier"
echo "# TYPE squid_textfile_last_run_timestamp_seconds gauge"
printf "squid_textfile_last_run_timestamp_seconds %d\n" "$(date +%s)"
