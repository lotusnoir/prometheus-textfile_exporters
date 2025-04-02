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
        "consul") 
            "$binary_path" --version | head -1| awk '{print $2}' | sed 's/v//'
            ;;
        "consul_exporter") 
            "$binary_path" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1
            ;;
        "keepalived_exporter")
            "$binary_path" -version 2>&1 | awk '{print $2}'
            ;;
        "fluentbit") 
            "$binary_path" --version | head -1| awk '{print $3}' | sed 's/v//'
            ;;
        "cadvisor") 
            "$binary_path" --version | head -1| awk '{print $3}' | sed 's/v//'
            ;;
        "snoopy")
            "$binary_path" version | head -1 | awk '{print $NF}'
            ;;
        "traefikee")
            docker exec -it traefik_proxy sh -c "traefikee version" | head -1 | awk '{print $2}' | sed 's/v//'
            ;;
        "squid_exporter") 
            "$binary_path" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1
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
    local version_pattern="${4:-[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}}"
    local prefix=$(echo "$app" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    # Special case for traefikee (docker container)
    if [ "$app" == "traefikee" ]; then
        if [ ! -f "/usr/bin/docker" ] || [ "$(docker ps -a | grep -c traefik_proxy)" -ne "1" ]; then
            return
        fi
    elif [ ! -f "$binary_path" ]; then
        return
    fi

    PRINT=1

    # Get versions
    local version=$(get_installed_version "$app" "$binary_path")
    [ "$?" -ne "0" ] && PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
    
    local version_latest=$(get_latest_version "$app" "$repo_url")
    [ "$?" -ne "0" ] && PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
    
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
    if [ "$(echo "$version" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$version_latest" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ]; then 
        declare -g "${prefix}_VERSION_SCRAPE"=1
        [ "$version" == "$version_latest" ] && declare -g "${prefix}_VERSION_MATCH"=1 || declare -g "${prefix}_VERSION_MATCH"=0
        [ "$version_major" == "$version_latest_major" ] && declare -g "${prefix}_VERSION_MAJOR_MATCH"=1 || declare -g "${prefix}_VERSION_MAJOR_MATCH"=0
    else
        declare -g "${prefix}_VERSION_SCRAPE"=0
    fi
}

## Main processing
# Define applications with their paths and repository URLs
declare -A apps=(
    ["node_exporter"]="/usr/local/bin/node_exporter https://api.github.com/repos/prometheus/node_exporter/releases/latest"
    ["chrony_exporter"]="/usr/local/bin/chrony_exporter https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest"
    ["conntrack_exporter"]="/usr/local/bin/conntrack_exporter https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest"
    ["blackbox_exporter"]="/usr/local/bin/blackbox_exporter https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest"
    ["rsyslog_exporter"]="/usr/local/bin/rsyslog_exporter https://api.github.com/repos/prometheus-community/rsyslog_exporter/releases/latest"
    ["keepalived_exporter"]="/usr/bin/keepalived_exporter https://api.github.com/repos/gen2brain/keepalived_exporter/releases/latest"
    ["fluentbit"]="/opt/fluent-bit/bin/fluent-bit https://api.github.com/repos/fluent/fluent-bit/releases/latest"
    ["cadvisor"]="/opt/cadvisor/cadvisor https://api.github.com/repos/google/cadvisor/releases/latest"
    ["consul"]="/usr/bin/consul https://api.github.com/repos/hashicorp/consul/releases/latest"
    ["consul_exporter"]="/usr/local/bin/consul_exporter https://api.github.com/repos/prometheus/consul_exporter/releases/latest"
    ["snoopy"]="/usr/sbin/snoopyctl https://api.github.com/repos/a2o/snoopy/releases/latest"
    ["traefikee"]="none https://doc.traefik.io/traefik-enterprise/kb/release-notes/"
    ["squid_exporter"]="/usr/local/bin/squid-exporter https://api.github.com/repos/boynux/squid-exporter/releases/latest"
)

# Process each application
for app in "${!apps[@]}"; do
    IFS=' ' read -r path url <<< "${apps[$app]}"
    #echo "START: processing: $app - $path - $url"
    process_app "$app" "$path" "$url"
done


########################################################################
### PRINT
########################################################################
if [ "$PRINT" -eq "1" ]; then
  #####################################
  echo "# HELP version_comparison Check binary version and latest version on repo project, 1 equals, 0 not equals"
  echo "# TYPE version_comparison gauge"
  declare -A version_map=(
    ["node_exporter"]="NODE_EXPORTER"
    ["chrony_exporter"]="CHRONY_EXPORTER"
    ["conntrack_exporter"]="CONNTRACK_EXPORTER"
    ["blackbox_exporter"]="BLACKBOX_EXPORTER"
    ["rsyslog_exporter"]="RSYSLOG_EXPORTER"
    ["keepalived_exporter"]="KEEPALIVED_EXPORTER"
    ["fluentbit"]="FLUENTBIT"
    ["cadvisor"]="CADVISOR"
    ["consul"]="CONSUL"
    ["consul_exporter"]="CONSUL_EXPORTER"
    ["snoopy"]="SNOOPY"
    ["traefikee"]="TRAEFIKEE"
    ["squid_exporter"]="SQUID_EXPORTER"
  )  

  for app in "${!version_map[@]}"; do
    prefix="${version_map[$app]}"
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

  for app in "${!version_map[@]}"; do
    prefix="${version_map[$app]}"
    match_var="${prefix}_VERSION_MAJOR_MATCH"
    installed_var="${prefix}_VERSION_MAJOR"
    latest_var="${prefix}_VERSION_LATEST_MAJOR"
  
    if [ -n "${!match_var}" ]; then
      echo "version_comparison_major{application=\"$app\",installed=\"${!installed_var}\",latest=\"${!latest_var}\"} ${!match_var}"
    fi
  done
 
  #####################################
  echo "# HELP version_comparison_scrape Check if versions were found 1 ok, 0 problem"
  echo "# TYPE version_comparison_scrape gauge"
  declare -A scrape_map=(
      ["node_exporter"]="$NODE_EXPORTER_VERSION_SCRAPE"
      ["chrony_exporter"]="$CHRONY_EXPORTER_VERSION_SCRAPE"
      ["conntrack_exporter"]="$CONNTRACK_EXPORTER_VERSION_SCRAPE"
      ["blackbox_exporter"]="$BLACKBOX_EXPORTER_VERSION_SCRAPE"
      ["rsyslog_exporter"]="$RSYSLOG_EXPORTER_VERSION_SCRAPE"
      ["keepalived_exporter"]="$KEEPALIVED_EXPORTER_VERSION_SCRAPE"
      ["fluentbit"]="$FLUENTBIT_VERSION_SCRAPE"
      ["cadvisor"]="$CADVISOR_VERSION_SCRAPE"
      ["consul"]="$CONSUL_VERSION_SCRAPE"
      ["consul_exporter"]="$CONSUL_EXPORTER_VERSION_SCRAPE"
      ["snoopy"]="$SNOOPY_VERSION_SCRAPE"
      ["traefikee"]="$TRAEFIKEE_VERSION_SCRAPE"
      ["squid_exporter"]="$SQUID_EXPORTER_VERSION_SCRAPE"
  )

  current_date=$(date +%s) # Unix timestamp format
  # Initialize all_ok flag
  all_ok=1

  # Print metrics and check values
  for app in "${!scrape_map[@]}"; do
      if [ -n "${scrape_map[$app]}" ]; then
          echo "version_comparison_scrape{application=\"$app\"} ${scrape_map[$app]}"
          
          # Check if value is not 1
          if [ "${scrape_map[$app]}" -ne 1 ]; then
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
