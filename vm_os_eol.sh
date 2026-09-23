#!/usr/bin/env bash
#===============================================================================
#         FILE:  os_eol_textfile.sh
#
#        USAGE:  ./os_eol_textfile.sh
#
#  DESCRIPTION:
#                Exposes OS release End-Of-Life (EOL) status (Debian, Ubuntu,
#                Linux Mint, RHEL, Rocky Linux, Oracle Linux) in Prometheus
#                textfile format. Prints metrics to stdout: caller is
#                responsible for the atomic write into the node_exporter
#                textfile collector dir.
#
#  REQUIREMENTS: bash 4+, date, /etc/os-release
#       AUTHOR:  Philippe LEAL
#      VERSION: 1.1
#      CREATED: 2026-09-18
#      UPDATED: 2026-09-23 (added Linux Mint support)
#===============================================================================

set -euo pipefail

# --- EOL reference table ---------------------------------------------------
# Key format: "<family>|<match>"
#   - debian/ubuntu  -> match = VERSION_CODENAME (bullseye, jammy, ...)
#   - rhel/rocky/ol   -> match = major version number only (7, 8, 9, 10)
#   - linuxmint       -> match = major version number only (19, 20, 21, 22)
#                        (Mint point releases 22, 22.1, 22.2, 22.3 all share
#                         the same Ubuntu LTS base and thus the same EOL date)
# Value format: "<display_version>:<eol_date YYYY-MM-DD>"
declare -A EOL_TABLE=(
  # --- Debian --- (LTS end date, see debian.org/releases)
  ["debian|stretch"]="9:2022-06-30"
  ["debian|buster"]="10:2024-06-30"
  ["debian|bullseye"]="11:2026-08-31"
  ["debian|bookworm"]="12:2028-06-30"
  ["debian|trixie"]="13:2028-08-09"

  # --- Ubuntu --- (standard/main support end, NOT Ubuntu Pro ESM)
  ["ubuntu|xenial"]="16.04:2021-04-30"
  ["ubuntu|bionic"]="18.04:2023-05-31"
  ["ubuntu|focal"]="20.04:2025-05-31"
  ["ubuntu|jammy"]="22.04:2027-05-31"
  ["ubuntu|noble"]="24.04:2029-05-31"
  ["ubuntu|resolute"]="26.04:2031-05-29"

  # --- Linux Mint --- (EOL mirrors the underlying Ubuntu LTS base; matched
  # on Mint's own major version number since Mint's own codenames, e.g.
  # "zena" for 22.3, don't correspond 1:1 with Ubuntu codenames)
  ["linuxmint|19"]="19:2023-05-31"   # based on Ubuntu 18.04 bionic
  ["linuxmint|20"]="20:2025-05-31"   # based on Ubuntu 20.04 focal
  ["linuxmint|21"]="21:2027-05-31"   # based on Ubuntu 22.04 jammy
  ["linuxmint|22"]="22:2029-05-31"   # based on Ubuntu 24.04 noble

  # --- RHEL --- (Maintenance Support end = last date of standard/free-tier
  # errata without a paid ELS add-on; RHEL 7's ELS runs to 2029-05-31)
  ["rhel|7"]="7:2024-06-30"
  ["rhel|8"]="8:2029-05-31"
  ["rhel|9"]="9:2032-05-31"
  ["rhel|10"]="10:2035-05-31"

  # --- Rocky Linux --- (mirrors RHEL's lifecycle, 10 years total)
  ["rocky|8"]="8:2029-05-31"
  ["rocky|9"]="9:2032-05-31"
  ["rocky|10"]="10:2035-05-31"

  # --- Oracle Linux --- (Extended Support end; included in standard Oracle
  # Linux support subscriptions, unlike RHEL's paid ELS. After this date only
  # indefinite/no-new-fixes "Sustaining Support" remains)
  ["ol|7"]="7:2029-07-31"
  ["ol|8"]="8:2032-07-31"
  ["ol|9"]="9:2035-06-30"
  ["ol|10"]="10:2038-06-30"
)
# ---------------------------------------------------------------------------

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    echo "ERROR: cannot read /etc/os-release" >&2
    exit 1
fi

ID_LOWER="${ID,,}"

case "${ID_LOWER}" in
    debian)
        FAMILY="debian"
        MATCH_KEY="${VERSION_CODENAME:-unknown}"
        ;;
    ubuntu)
        FAMILY="ubuntu"
        MATCH_KEY="${VERSION_CODENAME:-unknown}"
        ;;
    linuxmint)
        FAMILY="linuxmint"
        MATCH_KEY="${VERSION_ID%%.*}"
        ;;
    rhel)
        FAMILY="rhel"
        MATCH_KEY="${VERSION_ID%%.*}"
        ;;
    ol)
        FAMILY="ol"
        MATCH_KEY="${VERSION_ID%%.*}"
        ;;
    rocky)
        FAMILY="rocky"
        MATCH_KEY="${VERSION_ID%%.*}"
        ;;
    *)
        FAMILY="unknown"
        MATCH_KEY="unknown"
        ;;
esac

LOOKUP_KEY="${FAMILY}|${MATCH_KEY}"
ENTRY="${EOL_TABLE[${LOOKUP_KEY}]:-}"

if [[ -z "${ENTRY}" ]]; then
    echo "# HELP os_eol_info Lookup status of the OS EOL table for this host (1=found, 0=unknown)"
    echo "# TYPE os_eol_info gauge"
    echo "os_eol_info{family=\"${FAMILY}\",id=\"${MATCH_KEY}\"} 0"
    echo "WARNING: no EOL entry for family='${FAMILY}' id='${MATCH_KEY}' (VERSION_ID=${VERSION_ID:-n/a}) - update EOL_TABLE" >&2
    exit 0
fi

VERSION="${ENTRY%%:*}"
EOL_DATE="${ENTRY##*:}"
EOL_EPOCH=$(date -u -d "${EOL_DATE}" +%s)
NOW_EPOCH="${EPOCHSECONDS}"
REMAINING=$(( EOL_EPOCH - NOW_EPOCH ))
IS_EOL=0
(( REMAINING < 0 )) && IS_EOL=1

echo "# HELP os_eol_timestamp_seconds Unix timestamp of the OS release EOL date"
echo "# TYPE os_eol_timestamp_seconds gauge"
echo "os_eol_timestamp_seconds{family=\"${FAMILY}\",id=\"${MATCH_KEY}\",version=\"${VERSION}\"} ${EOL_EPOCH}"

echo "# HELP os_eol_seconds_remaining Seconds remaining before OS EOL (negative once past EOL)"
echo "# TYPE os_eol_seconds_remaining gauge"
echo "os_eol_seconds_remaining{family=\"${FAMILY}\",id=\"${MATCH_KEY}\",version=\"${VERSION}\"} ${REMAINING}"

echo "# HELP os_is_eol 1 if the running OS release is past its EOL date, else 0"
echo "# TYPE os_is_eol gauge"
echo "os_is_eol{family=\"${FAMILY}\",id=\"${MATCH_KEY}\",version=\"${VERSION}\"} ${IS_EOL}"

echo "# HELP os_eol_info Lookup status of the OS EOL table for this host (1=found, 0=unknown)"
echo "# TYPE os_eol_info gauge"
echo "os_eol_info{family=\"${FAMILY}\",id=\"${MATCH_KEY}\"} 1"
