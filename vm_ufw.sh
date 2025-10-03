#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_ufw.sh
#
#        USAGE:  ./vm_ufw.sh
#
#  DESCRIPTION:  
#
#  REQUIREMENTS: bash 4+, curl, jq
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION: 1.8
#      CREATED: 2025-10-02
#===============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

UFW_BIN=$(command -v ufw || true)
UFW_EXIST=0
UFW_STATE=0
UFW_SCRAPE_ERROR=0
UFW_VERSION="unknown"
UFW_RULES_COUNT=0

if [ -n "$UFW_BIN" ]; then
    UFW_EXIST=1
    UFW_VERSION=$("$UFW_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "unknown")
    STATUS=$("$UFW_BIN" status verbose 2>/dev/null || true)
    [[ "$STATUS" =~ "Status: active" ]] && UFW_STATE=1

    # Supprimer les lignes d'en-tête
    RULE_LINES=$(echo "$STATUS" | sed '1,2d' | sed '/^$/d')

    while IFS= read -r line; do
        # Supprimer les commentaires
        line="${line%%#*}"
        line="${line%%(*}" 
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        # Remplacer "Anywhere on lo" par "Loopback"
        line="${line//Anywhere on lo/Loopback}"

        # Ne conserver que les règles ALLOW ou DENY
        if ! [[ "$line" =~ ALLOW|DENY ]]; then
            continue
        fi

        # Split sur espaces multiples
        cols=()
        while read -r word; do
            [[ -n "$word" ]] && cols+=("$word")
        done < <(echo "$line" | tr -s ' ' '\n')

        [[ ${#cols[@]} -lt 2 ]] && continue

        to_port="${cols[0]}"
        action="${cols[1]}"
        direction="IN"
        from_port="Anywhere"
        protocol="both"
        from_ip="unknown"

        # Gestion OUT
        if [[ " ${cols[*]} " =~ OUT ]]; then
            direction="OUT"
            from_ip="Loopback"
        else
            # Chercher from_ip : première valeur ressemblant à une IP/subnet ou "Loopback"
            for c in "${cols[@]:2}"; do
                if [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$ ]] || [[ "$c" == "Loopback" ]]; then
                    from_ip="$c"
                    break
                fi
            done
            # Chercher from_port si présent (format ip port/proto)
            for c in "${cols[@]:2}"; do
                if [[ "$c" =~ ^[0-9]+/.* ]]; then
                    from_port="$c"
                    break
                fi
            done
        fi

        # Détecter protocole depuis to_port
        if [[ "$to_port" =~ /tcp$ ]]; then
            protocol="tcp"
            to_port="${to_port%%/*}"
        elif [[ "$to_port" =~ /udp$ ]]; then
            protocol="udp"
            to_port="${to_port%%/*}"
        fi

        UFW_RULES_COUNT=$((UFW_RULES_COUNT + 1))
        echo "ufw_rule{action=\"$action\",direction=\"$direction\",from_ip=\"$from_ip\",from_port=\"$from_port\",to_port=\"$to_port\",protocol=\"$protocol\",iface=\"all\"} 1"

    done <<< "$RULE_LINES"

else
    UFW_SCRAPE_ERROR=1
fi

# Metrics générales
echo "# HELP ufw_scrape_error 1 if an error occurred while scraping ufw"
echo "# TYPE ufw_scrape_error gauge"
echo "ufw_scrape_error $UFW_SCRAPE_ERROR"

echo "# HELP ufw_exist Check if ufw is installed"
echo "# TYPE ufw_exist gauge"
echo "ufw_exist $UFW_EXIST"

echo "# HELP ufw_up Check if ufw is running"
echo "# TYPE ufw_up gauge"
echo "ufw_up $UFW_STATE"

echo "# HELP ufw_version UFW version as reported by ufw binary"
echo "# TYPE ufw_version gauge"
echo "ufw_version{version=\"$UFW_VERSION\"} 1"

echo "# HELP ufw_rules_count Number of rules configured in ufw"
echo "# TYPE ufw_rules_count gauge"
echo "ufw_rules_count $UFW_RULES_COUNT"

exit $UFW_SCRAPE_ERROR
