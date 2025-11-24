#!/bin/bash

# Add proxy variables
if [ -f /etc/profile.d/proxy.sh ]; then
    source /etc/profile.d/proxy.sh
fi

#Check user is root
if [ -z "$USER" ] ; then USER=$(whoami); fi
if [ "$USER" != "root" ] ; then
    echo "$(basename "$0") must be run as root!"
    exit 2
fi

# Set global variables
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROBLEM_COUNT=0
PRINT=0
# Check on internet or take tab value (default)
INTERNET_SCRAPE="${INTERNET_SCRAPE:-0}"

# Define applications with their paths and repository URLs
declare -A apps=(
    ["node_exporter"]="/usr/local/bin/node_exporter https://api.github.com/repos/prometheus/node_exporter/releases/latest 1.10.2"
    ["chrony_exporter"]="/usr/local/bin/chrony_exporter https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest 0.12.1"
    ["conntrack_exporter"]="/usr/local/bin/conntrack_exporter https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest 0.3.1"
    ["blackbox_exporter"]="/usr/local/bin/blackbox_exporter https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest 0.27.0"
    ["rsyslog_exporter"]="/usr/local/bin/rsyslog_exporter https://api.github.com/repos/prometheus-community/rsyslog_exporter/releases/latest 1.1.0"
    ["keepalived_exporter"]="/usr/bin/keepalived_exporter https://api.github.com/repos/gen2brain/keepalived_exporter/releases/latest 0.7.1"
    ["fluentbit"]="/opt/fluent-bit/bin/fluent-bit https://api.github.com/repos/fluent/fluent-bit/releases/latest 4.2.0"
    ["cadvisor"]="/opt/cadvisor/cadvisor https://api.github.com/repos/google/cadvisor/releases/latest 0.53.0"
    ["consul"]="/usr/bin/consul https://api.github.com/repos/hashicorp/consul/releases/latest 1.22.0"
    ["consul_exporter"]="/usr/local/bin/consul_exporter https://api.github.com/repos/prometheus/consul_exporter/releases/latest 0.13.0"
    ["snoopy"]="/usr/sbin/snoopyctl https://api.github.com/repos/a2o/snoopy/releases/latest 2.5.2"
    ["traefikee"]="none https://doc.traefik.io/traefik-enterprise/kb/release-notes/ 2.12.5"
    ["squid_exporter"]="/usr/local/bin/squid-exporter https://api.github.com/repos/boynux/squid-exporter/releases/latest 0.13.0"
    ["systemd_exporter"]="/usr/local/bin/systemd_exporter https://api.github.com/repos/prometheus-community/systemd_exporter/releases/latest 0.7.0"
    ["process_exporter"]="/usr/local/bin/process_exporter https://api.github.com/repos/ncabatoff/process-exporter/releases/latest 0.8.7"
    ["redis_exporter"]="/usr/local/bin/redis_exporter https://api.github.com/repos/oliver006/redis_exporter/releases/latest 1.80.1"
    ["alloy"]="/usr/local/bin/redis_exporter https://api.github.com/repos/grafana/alloy/releases/latest 1.11.3"
    ["controlm"]="/opt/controlM_agent https://docs.bmc.com/xwiki/bin/view/Control-M-Orchestration/Control-M/workloadautomation 9.0.22.050 [0-9]+\.[0-9]+\.[0-9]+\.[0-9]{3}"
    ["postgresql_exporter"]="/usr/local/bin/postgres_exporter https://api.github.com/repos/prometheus-community/postgres_exporter/releases/latest 0.18.1"
    ["mysqld_exporter"]="/usr/local/bin/mysqld_exporter https://api.github.com/repos/prometheus/mysqld_exporter/releases/latest 0.18.0"
    ["logstash_exporter"]="/usr/local/bin/logstash-exporter https://api.github.com/repos/lotusnoir/prometheus-logstash-exporter/releases/latest 0.7.15"

    #["haproxy"]="
    #["kafka_exporter"]="
)

########################################################################
### Functions
########################################################################
# Get installed version
get_installed_version() {
    local app="$1"
    local binary_path="$2"

    case "$app" in
        "conntrack_exporter") echo "0.3.1" ;;
        "rsyslog_exporter") echo "1.1.0" ;;
        "logstash_exporter") echo "0.7.15" ;;
        "consul_exporter" | "systemd_exporter" | "postgresql_exporter" | "mysqld_exporter" | "squid_exporter")
            "$binary_path" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1
            ;;
        "fluentbit" | "cadvisor" | "alloy")
            "$binary_path" --version | head -1 | awk '{print $3}' | sed 's/v//'
            ;;
        "consul")
            "$binary_path" --version | head -1 | awk '{print $2}' | sed 's/v//'
            ;;
        "keepalived_exporter")
            "$binary_path" -version 2>&1 | awk '{print $2}'
            ;;
        "snoopy")
            "$binary_path" version | head -1 | awk '{print $NF}'
            ;;
        "traefikee")
            docker exec -it traefik_proxy sh -c "traefikee version" | head -1 | awk '{print $2}' | sed 's/v//'
            ;;
        "controlm")
           grep CODE_VERSION ${binary_path}/ctm/data/CONFIG.dat | awk '{print $NF}'
            ;;
        *)
            "$binary_path" --version | head -1 | awk '{print $3}'
            ;;
    esac
}

# Get latest version from source (GitHub or website)
get_latest_version() {
    local app="$1"
    local repo_url="$2"

    case "$app" in
        "traefikee")
            curl -s "$repo_url" | grep '<h2 id="v.*">v' | grep -oP '>v\K[^ ]+' | head -1
            ;;
        "snoopy")
            curl -s "$repo_url" | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -e 's/[-,]//gi' -e 's/snoopy//'
            ;;
        "controlm")
            curl -s "$repo_url" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{3}' | sort -ru | head -1
            ;;
        *)
            curl -s "$repo_url" | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi'
            ;;
    esac
}

# Process version checks for an application
process_app() {
    local app="$1"
    local binary_path="$2"
    local repo_url="$3"
    local version_latest="$4"
    local default_pattern='[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}'
    local version_pattern="${5:-$default_pattern}"
    local prefix=$(echo "$app" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    # Special case for traefikee (docker container)
    if [ "$app" == "traefikee" ]; then
        if [ ! -f "/usr/bin/docker" ] || [ "$(docker ps -a | grep -c traefik_proxy)" -ne "1" ]; then
            return
        fi
    elif [ ! -e "$binary_path" ]; then
        return
    fi

    PRINT=1

    # Get versions
    local version=$(get_installed_version "$app" "$binary_path")
    [ "$?" -ne "0" ] && PROBLEM_COUNT=$((PROBLEM_COUNT + 1))

    if [ "$INTERNET_SCRAPE" != 0 ]; then
        local version_latest=$(get_latest_version "$app" "$repo_url")
        [ "$?" -ne "0" ] && PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
    fi

    local version_major=${version%.*}
    local version_latest_major=${version_latest%.*}

    declare -g "${prefix}_VERSION"=$version
    declare -g "${prefix}_VERSION_LATEST"=$version_latest
    declare -g "${prefix}_VERSION_MAJOR"=$version_major
    declare -g "${prefix}_VERSION_LATEST_MAJOR"=$version_latest_major
    #echo "     etape1 process_app:"
    #echo "         version=$version"
    #echo "         version_latest=$version_latest"
    #echo "         version_major=$version_major"
    #echo "         version_latest_major=$version_latest_major"

    # Version validation and comparison
    if [ "$(echo "$version" | grep -c -E "$version_pattern")" -eq "1" ] && [ "$(echo "$version_latest" | grep -c -E "$version_pattern")" -eq "1" ]; then
        declare -g "${prefix}_VERSION_SCRAPE"=1
        [ "$version" == "$version_latest" ] && declare -g "${prefix}_VERSION_MATCH"=1 || declare -g "${prefix}_VERSION_MATCH"=0
        [ "$version_major" == "$version_latest_major" ] && declare -g "${prefix}_VERSION_MAJOR_MATCH"=1 || declare -g "${prefix}_VERSION_MAJOR_MATCH"=0
    else
        declare -g "${prefix}_VERSION_SCRAPE"=0
    fi
}

#####################################
## Main processing
#####################################
for app in "${!apps[@]}"; do
    IFS=' ' read -r path url version pattern <<< "${apps[$app]}"
    #echo "START: processing: $app - $path - $url" - "$version" - "$pattern"
    process_app "$app" "$path" "$url" "$version" "$pattern"
done


########################################################################
### PRINT
########################################################################
if [ "$PRINT" -eq "1" ]; then
  #####################################
  echo "# HELP version_comparison Check binary version and latest version on repo project, 1 equals, 0 not equals"
  echo "# TYPE version_comparison gauge"

  for app in "${!apps[@]}"; do
    prefix="${app^^}"
    match_var="${prefix}_VERSION_MATCH"
    installed_var="${prefix}_VERSION"
    latest_var="${prefix}_VERSION_LATEST"
    if [ -n "${!match_var}" ]; then
      echo "version_comparison{application=\"$app\",installed=\"${!installed_var}\",latest=\"${!latest_var}\"} ${!match_var}"
    fi
  done

  #####################################
  echo "# HELP version_comparison_major Check binary version and latest version only keeping the major version on repo project, 1 equals, 0 not equals"
  echo "# TYPE version_comparison_major gauge"

  for app in "${!apps[@]}"; do
    prefix="${app^^}"
    match_var="${prefix}_VERSION_MAJOR_MATCH"
    installed_var="${prefix}_VERSION_MAJOR"
    latest_var="${prefix}_VERSION_LATEST_MAJOR"
    if [ -n "${!match_var}" ]; then
      echo "version_comparison_major{application=\"$app\",installed=\"${!installed_var}\",latest=\"${!latest_var}\"} ${!match_var}"
    fi
  done

  #####################################
  echo "# HELP version_comparison_scrape_success Check if versions were found 1 ok, 0 problem"
  echo "# TYPE version_comparison_scrape_success gauge"

  current_date=$(date +%s) # Unix timestamp format
  # Initialize all_ok flag
  all_ok=1

  # Print metrics and check values
  for app in "${!apps[@]}"; do
    prefix="${app^^}"
    scrape_var="${prefix}_VERSION_SCRAPE"
    if [ -n "${!scrape_var}" ]; then
        echo "version_comparison_scrape_success{application=\"$app\"} ${!scrape_var}"

        # Check if value is not 1
        if [ "${!scrape_var}" -ne 1 ]; then
            all_ok=0
        fi
    fi
  done

  # Add a summary metric
  echo "# HELP version_comparison_all_scrapes_ok Check if all components scraped successfully"
  echo "# TYPE version_comparison_all_scrapes_ok gauge"
  echo "version_comparison_all_scrapes_ok{date=\"$current_date\"} $all_ok"

fi

### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
