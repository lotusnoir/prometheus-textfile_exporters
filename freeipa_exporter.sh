#!/bin/bash
# FreeIPA Prometheus Textfile Exporter
# Collects metrics about FreeIPA server health and connection status
# Output format: Prometheus textfile for node_exporter's textfile collector

# Configuration
BASE_DN=${BASE_DN:-unset}
OUTPUT_FILE=${OUTPUT_FILE:-/var/lib/node_exporter/freeipa.prom}
TEMP_FILE="${OUTPUT_FILE}.$$"

# LDAP socket detection (used throughout the script)
LDAP_SOCKET=$(ls /var/run/slapd-*.socket 2>/dev/null | head -1)
if [ -n "$LDAP_SOCKET" ]; then
    SOCKET_NAME=$(basename "$LDAP_SOCKET")
    LDAPI_URL="ldapi://%2fvar%2frun%2f${SOCKET_NAME}"
fi

# Function to safely write metrics
write_metric() {
    local metric_name="$1"
    local metric_value="$2"
    local metric_help="$3"
    local metric_type="$4"
    
    echo "# HELP ${metric_name} ${metric_help}" >> "${TEMP_FILE}"
    echo "# TYPE ${metric_name} ${metric_type}" >> "${TEMP_FILE}"
    echo "${metric_name} ${metric_value}" >> "${TEMP_FILE}"
}

# Function to safely write metric with labels (HELP and TYPE written separately)
write_metric_with_labels() {
    local metric_name="$1"
    local metric_value="$2"
    local metric_labels="$3"
    
    echo "${metric_name}{${metric_labels}} ${metric_value}" >> "${TEMP_FILE}"
}

# Function to write HELP and TYPE for a metric family (call once per family)
write_metric_header() {
    local metric_name="$1"
    local metric_help="$2"
    local metric_type="$3"
    
    echo "# HELP ${metric_name} ${metric_help}" >> "${TEMP_FILE}"
    echo "# TYPE ${metric_name} ${metric_type}" >> "${TEMP_FILE}"
}

# Function to safely get integer value
get_int() {
    local value="$1"
    # Remove non-numeric characters and ensure we have a number
    value=$(echo "$value" | grep -o '[0-9]\+' | head -1)
    if [ -z "$value" ]; then
        echo "0"
    else
        echo "$value"
    fi
}

# Start with a clean temp file
> "${TEMP_FILE}"

# Obtain Kerberos ticket for root (if using keytab)
if command -v kinit &>/dev/null && [ -f /etc/krb5.keytab ]; then
    kinit -k -t /etc/krb5.keytab host/$(hostname -f) 2>/dev/null
fi

## 1. LDAP Connections (from netstat)
#LDAP_CONNECTIONS=$(netstat -tn 2>/dev/null | grep -c ":389" || echo "0")
#LDAP_CONNECTIONS=$(get_int "$LDAP_CONNECTIONS")
#write_metric "freeipa_ldap_connections" "${LDAP_CONNECTIONS}" "Current number of LDAP connections on port 389" "gauge"
#
## 2. Secure LDAP Connections (LDAPS)
#LDAPS_CONNECTIONS=$(netstat -tn 2>/dev/null | grep -c ":636" || echo "0")
#LDAPS_CONNECTIONS=$(get_int "$LDAPS_CONNECTIONS")
#write_metric "freeipa_ldaps_connections" "${LDAPS_CONNECTIONS}" "Current number of LDAPS connections on port 636" "gauge"
#
## 3. Kerberos connections
#KRB5_CONNECTIONS=$(netstat -tn 2>/dev/null | grep -c ":88" || echo "0")
#KRB5_CONNECTIONS=$(get_int "$KRB5_CONNECTIONS")
#write_metric "freeipa_krb5_connections" "${KRB5_CONNECTIONS}" "Current number of Kerberos connections on port 88" "gauge"

# 4. Overall IPA server status via ping
if ipa ping &>/dev/null; then
    IPA_STATUS=1
else
    IPA_STATUS=0
fi
write_metric "freeipa_server_up" "${IPA_STATUS}" "IPA server ping status (1=up, 0=down)" "gauge"

# 5. IPA Health Check metrics (if ipa-healthcheck is available)
# 5. IPA Health Check metrics - CLEANED VERSION (no duplicates)
if command -v ipa-healthcheck &>/dev/null; then
    # Run healthcheck and get JSON output
    HEALTHCHECK_OUTPUT=$(ipa-healthcheck --output-type json 2>/dev/null | grep -v "^/usr/lib/python" | grep -v "deprecated")
    
    if [ -n "${HEALTHCHECK_OUTPUT}" ]; then
        # Count by severity (keep these for overview)
        ERROR_COUNT=$(echo "${HEALTHCHECK_OUTPUT}" | grep -c '"result": "ERROR"' || echo "0")
        ERROR_COUNT=$(get_int "$ERROR_COUNT")
        write_metric "freeipa_healthcheck_errors" "${ERROR_COUNT}" "Number of ERROR severity health check failures" "gauge"
        
        WARNING_COUNT=$(echo "${HEALTHCHECK_OUTPUT}" | grep -c '"result": "WARNING"' || echo "0")
        WARNING_COUNT=$(get_int "$WARNING_COUNT")
        write_metric "freeipa_healthcheck_warnings" "${WARNING_COUNT}" "Number of WARNING severity health check issues" "gauge"
        
        CRITICAL_COUNT=$(echo "${HEALTHCHECK_OUTPUT}" | grep -c '"result": "CRITICAL"' || echo "0")
        CRITICAL_COUNT=$(get_int "$CRITICAL_COUNT")
        write_metric "freeipa_healthcheck_critical" "${CRITICAL_COUNT}" "Number of CRITICAL severity health check failures" "gauge"
        
        # Overall health status
        if [ "${CRITICAL_COUNT}" -gt 0 ] || [ "${ERROR_COUNT}" -gt 0 ]; then
            OVERALL_HEALTH=2
        elif [ "${WARNING_COUNT}" -gt 0 ]; then
            OVERALL_HEALTH=1
        else
            OVERALL_HEALTH=0
        fi
        write_metric "freeipa_health_status" "${OVERALL_HEALTH}" "Overall health status (0=healthy, 1=warnings, 2=errors/critical)" "gauge"
        
        # Write header for detailed health check metrics (only one family)
        write_metric_header "freeipa_healthcheck_issues" "Health check issues with details" "gauge"
        
        # Parse JSON and create detailed metrics for each issue
        if command -v jq &>/dev/null; then
            # Use jq for proper JSON parsing
            echo "$HEALTHCHECK_OUTPUT" | jq -c '.[]' 2>/dev/null | while read -r check; do
                source=$(echo "$check" | jq -r '.source // "unknown"' | sed 's/[^a-zA-Z0-9:_-]/_/g')
                check_name=$(echo "$check" | jq -r '.check // "unknown"' | sed 's/[^a-zA-Z0-9:_-]/_/g')
                result=$(echo "$check" | jq -r '.result // "UNKNOWN"' | tr '[:upper:]' '[:lower:]')
                
                # Extract key and message from kw if available
                key=$(echo "$check" | jq -r '.kw.key // ""' | sed 's/[^a-zA-Z0-9:_-]/_/g')
                msg=$(echo "$check" | jq -r '.kw.msg // ""' | cut -c1-100 | sed 's/[^a-zA-Z0-9:_-]/_/g')
                
                # Build comprehensive labels
                labels="source=\"${source}\",check=\"${check_name}\",result=\"${result}\""
                [ -n "$key" ] && labels="${labels},key=\"${key}\""
                [ -n "$msg" ] && labels="${labels},message=\"${msg}\""
                
                # Write metric with value 1 (issue exists)
                write_metric_with_labels "freeipa_healthcheck_issues" "1" "${labels}"
            done
        else
            # Fallback to grep/sed parsing
            echo "$HEALTHCHECK_OUTPUT" | grep -o '{[^}]*}' | while read -r check_block; do
                source=$(echo "$check_block" | grep -o '"source":"[^"]*"' | cut -d'"' -f4 | sed 's/[^a-zA-Z0-9:_-]/_/g')
                check_name=$(echo "$check_block" | grep -o '"check":"[^"]*"' | cut -d'"' -f4 | sed 's/[^a-zA-Z0-9:_-]/_/g')
                result=$(echo "$check_block" | grep -o '"result":"[^"]*"' | cut -d'"' -f4 | tr '[:upper:]' '[:lower:]')
                key=$(echo "$check_block" | grep -o '"key":"[^"]*"' | cut -d'"' -f4 | sed 's/[^a-zA-Z0-9:_-]/_/g')
                
                if [ -n "$source" ] && [ -n "$check_name" ] && [ -n "$result" ]; then
                    labels="source=\"${source}\",check=\"${check_name}\",result=\"${result}\""
                    [ -n "$key" ] && labels="${labels},key=\"${key}\""
                    
                    write_metric_with_labels "freeipa_healthcheck_issues" "1" "${labels}"
                fi
            done
        fi
    else
        # Healthcheck ran but produced no output
        write_metric "freeipa_healthcheck_errors" "0" "Number of ERROR severity health check failures" "gauge"
        write_metric "freeipa_healthcheck_warnings" "0" "Number of WARNING severity health check issues" "gauge"
        write_metric "freeipa_healthcheck_critical" "0" "Number of CRITICAL severity health check failures" "gauge"
        write_metric "freeipa_health_status" "0" "Overall health status (0=healthy, 1=warnings, 2=errors/critical)" "gauge"
    fi
fi


# 6. Service status - DETAILED PER SERVICE METRICS
SERVICES_UP=0
SERVICES_TOTAL=0
if command -v ipactl &>/dev/null; then
    # Write header for service state metric family (only once)
    write_metric_header "freeipa_service_state" "IPA service state (1=running, 0=stopped)" "gauge"
    
    # Parse ipactl status and create detailed metrics
    while IFS= read -r line; do
        # Skip empty lines and header lines
        if [[ -n "$line" ]] && [[ ! "$line" =~ "---" ]] && [[ ! "$line" =~ "Status of" ]]; then
            # Extract service name and status
            if [[ "$line" =~ ([^:]+):[[:space:]]*(RUNNING|STOPPED) ]]; then
                service_name="${BASH_REMATCH[1]}"
                service_status="${BASH_REMATCH[2]}"
                
                # Clean up service name (remove leading/trailing whitespace)
                service_name=$(echo "$service_name" | xargs)
                
                # Increment counters
                ((SERVICES_TOTAL++))
                if [[ "$service_status" == "RUNNING" ]]; then
                    ((SERVICES_UP++))
                    # Running service = 1 with result="success"
                    write_metric_with_labels "freeipa_service_state" "1" "result=\"success\",service=\"${service_name}\""
                else
                    # Stopped service = 0 with result="stopped"
                    write_metric_with_labels "freeipa_service_state" "0" "result=\"stopped\",service=\"${service_name}\""
                fi
            fi
        fi
    done < <(ipactl status 2>/dev/null || echo "")
    
    SERVICES_UP=$(get_int "$SERVICES_UP")
    SERVICES_TOTAL=$(get_int "$SERVICES_TOTAL")
    
    write_metric "freeipa_services_up" "${SERVICES_UP}" "Number of IPA services currently running" "gauge"
    write_metric "freeipa_services_total" "${SERVICES_TOTAL}" "Total number of IPA services" "gauge"
fi

# 7. Replication status - WITH DETAILED SEGMENT METRICS
if command -v ipa &>/dev/null; then
    # Get domain level
    DOMAIN_LEVEL=$(ipa domainlevel-get 2>/dev/null | grep "domain level:" | awk '{print $NF}' || echo "1")
    DOMAIN_LEVEL=$(get_int "$DOMAIN_LEVEL")
    write_metric "freeipa_domain_level" "${DOMAIN_LEVEL}" "IPA domain level" "gauge"
    
    # Get topology information for domain
    TOPOLOGY_OUTPUT=$(ipa topologysegment-find domain 2>/dev/null)
    
    if [ -n "$TOPOLOGY_OUTPUT" ]; then
        # Count total segments
        TOTAL_SEGMENTS=$(echo "$TOPOLOGY_OUTPUT" | grep -c "Segment name:" || echo "0")
        TOTAL_SEGMENTS=$(get_int "$TOTAL_SEGMENTS")
        write_metric "freeipa_topology_segments" "${TOTAL_SEGMENTS}" "Total number of topology segments (replication agreements)" "gauge"
        
        # Write header for segment metrics
        write_metric_header "freeipa_topology_segment_info" "Topology segment information" "gauge"
        
        # Parse segment details
        SEGMENT_NAME=""
        LEFT_NODE=""
        RIGHT_NODE=""
        CONNECTIVITY=""
        
        while IFS= read -r line; do
            # Extract segment details
            if [[ "$line" =~ ^[[:space:]]+Segment[[:space:]]name:[[:space:]](.+)$ ]]; then
                # If we have a previous segment, process it
                if [ -n "$SEGMENT_NAME" ] && [ -n "$LEFT_NODE" ] && [ -n "$RIGHT_NODE" ]; then
                    # Clean up values for labels
                    seg_name_clean=$(echo "$SEGMENT_NAME" | sed 's/[^a-zA-Z0-9:_-]/_/g')
                    left_node_clean=$(echo "$LEFT_NODE" | sed 's/[^a-zA-Z0-9:_-]/_/g')
                    right_node_clean=$(echo "$RIGHT_NODE" | sed 's/[^a-zA-Z0-9:_-]/_/g')
                    
                    # Create labels
                    labels="segment=\"${seg_name_clean}\",left_node=\"${left_node_clean}\",right_node=\"${right_node_clean}\""
                    [ -n "$CONNECTIVITY" ] && labels="${labels},connectivity=\"${CONNECTIVITY}\""
                    
                    # Write metric with value 1 (segment exists)
                    write_metric_with_labels "freeipa_topology_segment_info" "1" "${labels}"
                fi
                
                # Start new segment
                SEGMENT_NAME="${BASH_REMATCH[1]}"
                LEFT_NODE=""
                RIGHT_NODE=""
                CONNECTIVITY=""
            elif [[ "$line" =~ ^[[:space:]]+Left[[:space:]]node:[[:space:]](.+)$ ]]; then
                LEFT_NODE="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+Right[[:space:]]node:[[:space:]](.+)$ ]]; then
                RIGHT_NODE="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+Connectivity:[[:space:]](.+)$ ]]; then
                CONNECTIVITY="${BASH_REMATCH[1]}"
            fi
        done <<< "$TOPOLOGY_OUTPUT"
        
        # Process the last segment
        if [ -n "$SEGMENT_NAME" ] && [ -n "$LEFT_NODE" ] && [ -n "$RIGHT_NODE" ]; then
            # Clean up values for labels
            seg_name_clean=$(echo "$SEGMENT_NAME" | sed 's/[^a-zA-Z0-9:_-]/_/g')
            left_node_clean=$(echo "$LEFT_NODE" | sed 's/[^a-zA-Z0-9:_-]/_/g')
            right_node_clean=$(echo "$RIGHT_NODE" | sed 's/[^a-zA-Z0-9:_-]/_/g')
            
            # Create labels
            labels="segment=\"${seg_name_clean}\",left_node=\"${left_node_clean}\",right_node=\"${right_node_clean}\""
            [ -n "$CONNECTIVITY" ] && labels="${labels},connectivity=\"${CONNECTIVITY}\""
            
            # Write metric with value 1 (segment exists)
            write_metric_with_labels "freeipa_topology_segment_info" "1" "${labels}"
        fi
        
        # Also create metrics for segments involving this server
        LOCAL_HOSTNAME=$(hostname -f)
        
        # Count segments where this server is left node
        LEFT_COUNT=$(echo "$TOPOLOGY_OUTPUT" | grep -c "Left node:.*${LOCAL_HOSTNAME}" || echo "0")
        LEFT_COUNT=$(get_int "$LEFT_COUNT")
        write_metric_with_labels "freeipa_topology_segments_by_node" "${LEFT_COUNT}" "node=\"${LOCAL_HOSTNAME}\",role=\"left\""
        
        # Count segments where this server is right node
        RIGHT_COUNT=$(echo "$TOPOLOGY_OUTPUT" | grep -c "Right node:.*${LOCAL_HOSTNAME}" || echo "0")
        RIGHT_COUNT=$(get_int "$RIGHT_COUNT")
        write_metric_with_labels "freeipa_topology_segments_by_node" "${RIGHT_COUNT}" "node=\"${LOCAL_HOSTNAME}\",role=\"right\""
        
        # Total segments for this server
        TOTAL_FOR_SERVER=$((LEFT_COUNT + RIGHT_COUNT))
        write_metric_with_labels "freeipa_topology_segments_total_by_node" "${TOTAL_FOR_SERVER}" "node=\"${LOCAL_HOSTNAME}\""
    fi
    
    # Check server roles
    LOCAL_HOSTNAME=$(hostname -f)
    SERVER_STATUS=$(ipa server-show "$LOCAL_HOSTNAME" 2>/dev/null)
    
    if [ -n "$SERVER_STATUS" ]; then
        # Count enabled roles
        ROLES_LINE=$(echo "$SERVER_STATUS" | grep "Enabled server roles:" | sed 's/Enabled server roles: //')
        if [ -n "$ROLES_LINE" ]; then
            # Count the roles (comma-separated list)
            ROLE_COUNT=$(echo "$ROLES_LINE" | tr ',' '\n' | wc -l)
            ROLE_COUNT=$(get_int "$ROLE_COUNT")
            write_metric "freeipa_server_roles" "${ROLE_COUNT}" "Number of enabled roles on this server" "gauge"
            
            # Create individual role metrics
            IFS=',' read -ra ROLES <<< "$ROLES_LINE"
            for role in "${ROLES[@]}"; do
                # Trim whitespace
                role=$(echo "$role" | xargs)
                # Convert to prometheus-friendly format (lowercase, underscores)
                role_clean=$(echo "$role" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
                write_metric_with_labels "freeipa_role_enabled" "1" "role=\"${role_clean}\",name=\"${role}\""
            done
        fi
    fi
    
    # List all servers in topology
    SERVER_COUNT=$(ipa server-find --raw 2>/dev/null | grep -c "^  cn:" || echo "0")
    SERVER_COUNT=$(get_int "$SERVER_COUNT")
    write_metric "freeipa_servers_total" "${SERVER_COUNT}" "Total number of IPA servers in topology" "gauge"
    
    # Create individual server metrics
    if [ "$SERVER_COUNT" -gt 0 ]; then
        # Write header for server status metric family
        write_metric_header "freeipa_server_info" "IPA server information" "gauge"
        
        # Extract each server name and create a metric
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]+cn:[[:space:]](.+)$ ]]; then
                server_name="${BASH_REMATCH[1]}"
                # Create a metric for each server (value 1 means server exists)
                write_metric_with_labels "freeipa_server_info" "1" "server=\"${server_name}\""
            fi
        done < <(ipa server-find --raw 2>/dev/null)
    fi
    
    # Check replication using ipa-replica-manage for basic status
    if command -v ipa-replica-manage &>/dev/null; then
        # Check replication agreements
        REPLICA_INFO=$(ipa-replica-manage list "$LOCAL_HOSTNAME" 2>/dev/null)
        if [ -n "$REPLICA_INFO" ]; then
            REPLICA_COUNT=$(echo "$REPLICA_INFO" | grep -v "^$" | wc -l)
            REPLICA_COUNT=$(get_int "$REPLICA_COUNT")
            write_metric "freeipa_replicas_connected" "${REPLICA_COUNT}" "Number of replicas connected to this server" "gauge"
        fi
    fi
fi

## 8. Certificate expiry (using getcert list)
if command -v getcert &>/dev/null; then
    # Get certificate list
    CERT_LIST=$(getcert list 2>/dev/null)
    
    if [ -n "$CERT_LIST" ]; then
        # Count total certificates
        TOTAL_CERTS=$(echo "$CERT_LIST" | grep -c "Request ID" || echo "0")
        TOTAL_CERTS=$(get_int "$TOTAL_CERTS")
        write_metric "freeipa_certificates_total" "${TOTAL_CERTS}" "Total number of certificates monitored by certmonger" "gauge"
        
        # Write header for per-certificate metrics
        write_metric_header "freeipa_certificate_info" "Certificate information with expiry days" "gauge"
        
        # Parse certificates for per-certificate metrics
        REQUEST_ID=""
        CERT_NICKNAME=""
        CERT_STATUS=""
        CERT_EXPIRES=""
        CERT_ISSUER=""
        CERT_CA=""
        CERT_SUBJECT=""
        
        while IFS= read -r line; do
            # New certificate block starts with "Request ID 'xxxx':"
            if [[ "$line" =~ ^Request[[:space:]]ID[[:space:]]\'([^\']+)\': ]]; then
                # If we have a previous certificate with at least an expiry date, process it
                if [ -n "$REQUEST_ID" ] && [ -n "$CERT_EXPIRES" ]; then
                    # Calculate days until expiry
                    expires_epoch=$(date -d "$CERT_EXPIRES" +%s 2>/dev/null)
                    if [ -n "$expires_epoch" ] && [ "$expires_epoch" -gt 0 ] 2>/dev/null; then
                        now_epoch=$(date +%s)
                        days_left=$(( (expires_epoch - now_epoch) / 86400 ))
                        days_left=$(get_int "$days_left")
                        
                        # Determine the best identifier for this certificate
                        if [ -n "$CERT_NICKNAME" ]; then
                            cert_id="$CERT_NICKNAME"
                            id_type="nickname"
                        elif [ -n "$CERT_SUBJECT" ]; then
                            # Extract CN from subject if possible
                            if [[ "$CERT_SUBJECT" =~ CN=([^,]+) ]]; then
                                cert_id="${BASH_REMATCH[1]}"
                            else
                                cert_id="$CERT_SUBJECT"
                            fi
                            id_type="subject"
                        else
                            cert_id="cert_${REQUEST_ID}"
                            id_type="request_id"
                        fi
                        
                        # Clean up certificate name for label
                        cert_id_clean=$(echo "$cert_id" | sed 's/[^a-zA-Z0-9:_-]/_/g' | cut -c1-100)
                        
                        # Create certificate info metric with all details
                        labels="${id_type}=\"${cert_id_clean}\""
                        [ -n "$CERT_STATUS" ] && labels="${labels},status=\"${CERT_STATUS}\""
                        [ -n "$CERT_ISSUER" ] && labels="${labels},issuer=\"${CERT_ISSUER}\""
                        [ -n "$CERT_CA" ] && labels="${labels},ca=\"${CERT_CA}\""
                        [ -n "$REQUEST_ID" ] && labels="${labels},request_id=\"${REQUEST_ID}\""
                        
                        write_metric_with_labels "freeipa_certificate_info" "${days_left}" "${labels}"
                    fi
                fi
                
                # Start new certificate - reset variables
                REQUEST_ID="${BASH_REMATCH[1]}"
                CERT_NICKNAME=""
                CERT_STATUS=""
                CERT_EXPIRES=""
                CERT_ISSUER=""
                CERT_CA=""
                CERT_SUBJECT=""
            fi
            
            # Extract certificate details - multiple patterns to catch all formats
            if [[ "$line" =~ ^[[:space:]]+key[[:space:]]pair[[:space:]]storage:.*nickname=\'([^\']+)\' ]]; then
                CERT_NICKNAME="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+certificate:.*nickname=\'([^\']+)\' ]]; then
                # Some certificates might have nickname in certificate line instead
                if [ -z "$CERT_NICKNAME" ]; then
                    CERT_NICKNAME="${BASH_REMATCH[1]}"
                fi
            elif [[ "$line" =~ ^[[:space:]]+key[[:space:]]pair[[:space:]]storage:[[:space:]]type=FILE,location=\'([^\']+)\' ]]; then
                # For FILE storage, use the filename as identifier
                filename=$(basename "${BASH_REMATCH[1]}")
                CERT_NICKNAME="${filename}"
            elif [[ "$line" =~ ^[[:space:]]+status:[[:space:]](.+) ]]; then
                CERT_STATUS="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+expires:[[:space:]](.+) ]]; then
                CERT_EXPIRES="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+issuer:[[:space:]](.+) ]]; then
                CERT_ISSUER="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+CA:[[:space:]](.+) ]]; then
                CERT_CA="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+subject:[[:space:]](.+) ]]; then
                CERT_SUBJECT="${BASH_REMATCH[1]}"
            fi
        done <<< "$CERT_LIST"
        
        # Process the last certificate
        if [ -n "$REQUEST_ID" ] && [ -n "$CERT_EXPIRES" ]; then
            # Calculate days until expiry
            expires_epoch=$(date -d "$CERT_EXPIRES" +%s 2>/dev/null)
            if [ -n "$expires_epoch" ] && [ "$expires_epoch" -gt 0 ] 2>/dev/null; then
                now_epoch=$(date +%s)
                days_left=$(( (expires_epoch - now_epoch) / 86400 ))
                days_left=$(get_int "$days_left")
                
                # Determine the best identifier for this certificate
                if [ -n "$CERT_NICKNAME" ]; then
                    cert_id="$CERT_NICKNAME"
                    id_type="nickname"
                elif [ -n "$CERT_SUBJECT" ]; then
                    # Extract CN from subject if possible
                    if [[ "$CERT_SUBJECT" =~ CN=([^,]+) ]]; then
                        cert_id="${BASH_REMATCH[1]}"
                    else
                        cert_id="$CERT_SUBJECT"
                    fi
                    id_type="subject"
                else
                    cert_id="cert_${REQUEST_ID}"
                    id_type="request_id"
                fi
                
                # Clean up certificate name for label
                cert_id_clean=$(echo "$cert_id" | sed 's/[^a-zA-Z0-9:_-]/_/g' | cut -c1-100)
                
                # Create certificate info metric with all details
                labels="${id_type}=\"${cert_id_clean}\""
                [ -n "$CERT_STATUS" ] && labels="${labels},status=\"${CERT_STATUS}\""
                [ -n "$CERT_ISSUER" ] && labels="${labels},issuer=\"${CERT_ISSUER}\""
                [ -n "$CERT_CA" ] && labels="${labels},ca=\"${CERT_CA}\""
                [ -n "$REQUEST_ID" ] && labels="${labels},request_id=\"${REQUEST_ID}\""
                
                write_metric_with_labels "freeipa_certificate_info" "${days_left}" "${labels}"
            fi
        fi
    fi
fi


# 9. Basic system resources for IPA - with actual monitor data
if command -v ldapsearch &>/dev/null && [ -n "$LDAP_SOCKET" ]; then
    # Get LDAP server version and info
    LDAP_VERSION=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -s base -b "cn=config" vendorVersion 2>/dev/null | grep "^vendorVersion:" | cut -d' ' -f2- | head -1)
    if [ -n "$LDAP_VERSION" ]; then
        write_metric_with_labels "freeipa_ldap_info" "1" "version=\"${LDAP_VERSION}\"" "LDAP server information" "gauge"
    fi
    
    # Get monitor data from base cn=monitor
    MONITOR_DATA=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=monitor" 2>/dev/null)
    
    if [ -n "$MONITOR_DATA" ]; then
        # Connection metrics
        CURRENT_CONN=$(echo "$MONITOR_DATA" | grep "^currentconnections:" | awk '{print $2}' || echo "0")
        CURRENT_CONN=$(get_int "$CURRENT_CONN")
        write_metric "freeipa_ldap_current_connections" "${CURRENT_CONN}" "Current number of connections to LDAP server" "gauge"
        
        TOTAL_CONN=$(echo "$MONITOR_DATA" | grep "^totalconnections:" | awk '{print $2}' || echo "0")
        TOTAL_CONN=$(get_int "$TOTAL_CONN")
        write_metric "freeipa_ldap_total_connections" "${TOTAL_CONN}" "Total connections to LDAP server since start" "counter"
        
        # Connection at max threads
        CONN_MAX_THREADS=$(echo "$MONITOR_DATA" | grep "^currentconnectionsatmaxthreads:" | awk '{print $2}' || echo "0")
        CONN_MAX_THREADS=$(get_int "$CONN_MAX_THREADS")
        write_metric "freeipa_ldap_connections_at_max_threads" "${CONN_MAX_THREADS}" "Current connections at max threads" "gauge"
        
        MAX_THREADS_HITS=$(echo "$MONITOR_DATA" | grep "^maxthreadsperconnhits:" | awk '{print $2}' || echo "0")
        MAX_THREADS_HITS=$(get_int "$MAX_THREADS_HITS")
        write_metric "freeipa_ldap_max_threads_hits" "${MAX_THREADS_HITS}" "Max threads per connection hits" "counter"
        
        # File descriptor table size
        DTABLE_SIZE=$(echo "$MONITOR_DATA" | grep "^dtablesize:" | awk '{print $2}' || echo "0")
        DTABLE_SIZE=$(get_int "$DTABLE_SIZE")
        write_metric "freeipa_ldap_dtablesize" "${DTABLE_SIZE}" "File descriptor table size" "gauge"
        
        # Read waiters
        READ_WAITERS=$(echo "$MONITOR_DATA" | grep "^readwaiters:" | awk '{print $2}' || echo "0")
        READ_WAITERS=$(get_int "$READ_WAITERS")
        write_metric "freeipa_ldap_read_waiters" "${READ_WAITERS}" "Number of read waiters" "gauge"
        
        # Operations metrics
        OPS_INITIATED=$(echo "$MONITOR_DATA" | grep "^opsinitiated:" | awk '{print $2}' || echo "0")
        OPS_INITIATED=$(get_int "$OPS_INITIATED")
        write_metric "freeipa_ldap_ops_initiated" "${OPS_INITIATED}" "Total operations initiated" "counter"
        
        OPS_COMPLETED=$(echo "$MONITOR_DATA" | grep "^opscompleted:" | awk '{print $2}' || echo "0")
        OPS_COMPLETED=$(get_int "$OPS_COMPLETED")
        write_metric "freeipa_ldap_ops_completed" "${OPS_COMPLETED}" "Total operations completed" "counter"
        
        # Entries and bytes sent
        ENTRIES_SENT=$(echo "$MONITOR_DATA" | grep "^entriessent:" | awk '{print $2}' || echo "0")
        ENTRIES_SENT=$(get_int "$ENTRIES_SENT")
        write_metric "freeipa_ldap_entries_sent" "${ENTRIES_SENT}" "Total entries sent" "counter"
        
        BYTES_SENT=$(echo "$MONITOR_DATA" | grep "^bytessent:" | awk '{print $2}' || echo "0")
        BYTES_SENT=$(get_int "$BYTES_SENT")
        write_metric "freeipa_ldap_bytes_sent" "${BYTES_SENT}" "Total bytes sent" "counter"
        
        # Uptime metrics
        CURRENT_TIME=$(echo "$MONITOR_DATA" | grep "^currenttime:" | awk '{print $2}' || echo "0")
        START_TIME=$(echo "$MONITOR_DATA" | grep "^starttime:" | awk '{print $2}' || echo "0")
        if [ "$CURRENT_TIME" != "0" ] && [ "$START_TIME" != "0" ]; then
            # Convert to epoch for uptime calculation
            CURRENT_EPOCH=$(date -d "$(echo $CURRENT_TIME | sed 's/\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')" +%s 2>/dev/null)
            START_EPOCH=$(date -d "$(echo $START_TIME | sed 's/\(....\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')" +%s 2>/dev/null)
            if [ -n "$CURRENT_EPOCH" ] && [ -n "$START_EPOCH" ]; then
                UPTIME=$((CURRENT_EPOCH - START_EPOCH))
                write_metric "freeipa_ldap_uptime_seconds" "${UPTIME}" "LDAP server uptime in seconds" "counter"
            fi
        fi
        
        # Backends count
        NBACKENDS=$(echo "$MONITOR_DATA" | grep "^nbackends:" | awk '{print $2}' || echo "0")
        NBACKENDS=$(get_int "$NBACKENDS")
        write_metric "freeipa_ldap_backends" "${NBACKENDS}" "Number of backends" "gauge"
    fi
    
    # Get SNMP counters data
    SNMP_DATA=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=snmp,cn=monitor" 2>/dev/null)
    
    if [ -n "$SNMP_DATA" ]; then
        # Authentication metrics
        ANON_BINDS=$(echo "$SNMP_DATA" | grep "^anonymousbinds:" | awk '{print $2}' || echo "0")
        ANON_BINDS=$(get_int "$ANON_BINDS")
        write_metric "freeipa_ldap_anonymous_binds" "${ANON_BINDS}" "Anonymous binds" "counter"
        
        UNAUTH_BINDS=$(echo "$SNMP_DATA" | grep "^unauthbinds:" | awk '{print $2}' || echo "0")
        UNAUTH_BINDS=$(get_int "$UNAUTH_BINDS")
        write_metric "freeipa_ldap_unauth_binds" "${UNAUTH_BINDS}" "Unauthenticated binds" "counter"
        
        SIMPLE_BINDS=$(echo "$SNMP_DATA" | grep "^simpleauthbinds:" | awk '{print $2}' || echo "0")
        SIMPLE_BINDS=$(get_int "$SIMPLE_BINDS")
        write_metric "freeipa_ldap_simple_binds" "${SIMPLE_BINDS}" "Simple authentication binds" "counter"
        
        STRONG_BINDS=$(echo "$SNMP_DATA" | grep "^strongauthbinds:" | awk '{print $2}' || echo "0")
        STRONG_BINDS=$(get_int "$STRONG_BINDS")
        write_metric "freeipa_ldap_strong_binds" "${STRONG_BINDS}" "Strong authentication binds" "counter"
        
        # Error metrics
        BIND_SEC_ERRORS=$(echo "$SNMP_DATA" | grep "^bindsecurityerrors:" | awk '{print $2}' || echo "0")
        BIND_SEC_ERRORS=$(get_int "$BIND_SEC_ERRORS")
        write_metric "freeipa_ldap_bind_security_errors" "${BIND_SEC_ERRORS}" "Bind security errors" "counter"
        
        SEC_ERRORS=$(echo "$SNMP_DATA" | grep "^securityerrors:" | awk '{print $2}' || echo "0")
        SEC_ERRORS=$(get_int "$SEC_ERRORS")
        write_metric "freeipa_ldap_security_errors" "${SEC_ERRORS}" "Security errors" "counter"
        
        ERRORS=$(echo "$SNMP_DATA" | grep "^errors:" | awk '{print $2}' || echo "0")
        ERRORS=$(get_int "$ERRORS")
        write_metric "freeipa_ldap_errors" "${ERRORS}" "Total errors" "counter"
        
        # Operation types
        SEARCH_OPS=$(echo "$SNMP_DATA" | grep "^searchops:" | awk '{print $2}' || echo "0")
        SEARCH_OPS=$(get_int "$SEARCH_OPS")
        write_metric "freeipa_ldap_search_ops" "${SEARCH_OPS}" "Search operations" "counter"
        
        MODIFY_OPS=$(echo "$SNMP_DATA" | grep "^modifyentryops:" | awk '{print $2}' || echo "0")
        MODIFY_OPS=$(get_int "$MODIFY_OPS")
        write_metric "freeipa_ldap_modify_ops" "${MODIFY_OPS}" "Modify operations" "counter"
        
        # Entries returned
        ENTRIES_RETURNED=$(echo "$SNMP_DATA" | grep "^entriesreturned:" | awk '{print $2}' || echo "0")
        ENTRIES_RETURNED=$(get_int "$ENTRIES_RETURNED")
        write_metric "freeipa_ldap_entries_returned" "${ENTRIES_RETURNED}" "Entries returned" "counter"
    fi
fi

# 9bis. Extra stats about IPA content and services
if [ -n "$LDAP_SOCKET" ] && command -v ldapsearch &>/dev/null; then
    # Method 1: Count all entries in the directory (accurate but potentially slow)
    TOTAL_ENTRIES=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "${BASE_DN}" "(objectclass=*)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    TOTAL_ENTRIES=$(get_int "$TOTAL_ENTRIES")
    write_metric "freeipa_ldap_db_size_entries" "${TOTAL_ENTRIES}" "Number of entries in LDAP database" "gauge"
    
    # Count specific object types for better visibility
    # Count all posix accounts (users)
    USER_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=users,cn=accounts,${BASE_DN}" "(objectclass=posixaccount)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    USER_COUNT=$(get_int "$USER_COUNT")
    write_metric "freeipa_ldap_users" "${USER_COUNT}" "Number of user entries in LDAP" "gauge"
    
    # Count all groups
    GROUP_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=groups,cn=accounts,${BASE_DN}" "(objectclass=posixgroup)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    GROUP_COUNT=$(get_int "$GROUP_COUNT")
    write_metric "freeipa_ldap_groups" "${GROUP_COUNT}" "Number of group entries in LDAP" "gauge"
    
    # Count all hosts
    HOST_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=computers,cn=accounts,${BASE_DN}" "(objectclass=ipahost)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    HOST_COUNT=$(get_int "$HOST_COUNT")
    write_metric "freeipa_ldap_hosts" "${HOST_COUNT}" "Number of host entries in LDAP" "gauge"
    
    ## Count all services
    #SERVICE_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=services,cn=accounts,${BASE_DN}" "(objectclass=ipaservice)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    #SERVICE_COUNT=$(get_int "$SERVICE_COUNT")
    #write_metric "freeipa_services" "${SERVICE_COUNT}" "Number of service principals" "gauge"
    
    # Count sudo rules
    SUDO_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=sudorules,cn=sudo,${BASE_DN}" "(objectclass=ipasudorule)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    SUDO_COUNT=$(get_int "$SUDO_COUNT")
    write_metric "freeipa_sudo_rules" "${SUDO_COUNT}" "Number of sudo rules" "gauge"
    
    # Count HBAC rules
    HBAC_COUNT=$(ldapsearch -LLL -Y EXTERNAL -H "$LDAPI_URL" -b "cn=hbac,${BASE_DN}" "(objectclass=ipahbacrule)" dn 2>/dev/null | grep -c "^dn:" || echo "0")
    HBAC_COUNT=$(get_int "$HBAC_COUNT")
    write_metric "freeipa_hbac_rules" "${HBAC_COUNT}" "Number of HBAC rules" "gauge"
fi

# Kerberos resources
if command -v klist &>/dev/null; then
    # Check if krb5kdc is running
    if pgrep -f krb5kdc >/dev/null 2>&1; then
        KRB5_RUNNING=1
    else
        KRB5_RUNNING=0
    fi
    write_metric "freeipa_krb5_running" "${KRB5_RUNNING}" "Kerberos KDC service running (1=yes, 0=no)" "gauge"
    
    # Count active Kerberos tickets - count service principal lines
    KRB5_TICKETS=$(klist -5 2>/dev/null | grep -c "^[[:space:]]*[0-9][0-9]/" || echo "0")
    KRB5_TICKETS=$(get_int "$KRB5_TICKETS")
    write_metric "freeipa_krb5_tickets" "${KRB5_TICKETS}" "Number of active Kerberos tickets" "gauge"
    
    # Also get the default principal
    DEFAULT_PRINCIPAL=$(klist -5 2>/dev/null | grep "Default principal:" | sed 's/Default principal: //')
    if [ -n "$DEFAULT_PRINCIPAL" ]; then
        write_metric_with_labels "freeipa_krb5_default_principal" "1" "principal=\"${DEFAULT_PRINCIPAL}\"" "Default Kerberos principal" "gauge"
    fi
fi

# HTTPD resources
if command -v systemctl &>/dev/null; then
    if systemctl is-active httpd >/dev/null 2>&1; then
        HTTPD_RUNNING=1
    else
        HTTPD_RUNNING=0
    fi
    write_metric "freeipa_httpd_running" "${HTTPD_RUNNING}" "HTTPD service running (1=yes, 0=no)" "gauge"
    
    HTTPD_PROCESSES=$(pgrep -f httpd | wc -l)
    HTTPD_PROCESSES=$(get_int "$HTTPD_PROCESSES")
    write_metric "freeipa_httpd_processes" "${HTTPD_PROCESSES}" "Number of HTTPD processes" "gauge"
fi

# SSSD resources
if command -v sssctl &>/dev/null; then
    SSSD_DOMAIN=$(sssctl domain-list 2>/dev/null)
    SSSD_HEALTH=$(sssctl domain-status $SSSD_DOMAIN 2>/dev/null | grep -c "Online status: Online" || echo "0")
    SSSD_HEALTH=$(get_int "$SSSD_HEALTH")
    write_metric "freeipa_sssd_online_domains" "${SSSD_HEALTH}" "Number of SSSD domains online" "gauge"
    
    if pgrep -f sssd >/dev/null 2>&1; then
        SSSD_RUNNING=1
    else
        SSSD_RUNNING=0
    fi
    write_metric "freeipa_sssd_running" "${SSSD_RUNNING}" "SSSD service running (1=yes, 0=no)" "gauge"
fi

# Last success timestamp
write_metric "freeipa_last_success" "$(date +%s)" "Timestamp of last successful metric collection" "gauge"

# Atomically move temp file to final location
mv "${TEMP_FILE}" "${OUTPUT_FILE}"

# Set permissions
chmod 644 "${OUTPUT_FILE}"

echo "FreeIPA metrics written to ${OUTPUT_FILE}"
