#!/usr/bin/env bash
#===============================================================================
#         FILE:  docker_container_infos.sh
#
#        USAGE:  ./docker_container_infos.sh
#
#  DESCRIPTION: Docker container and network information for Prometheus.
#
#  REQUIREMENTS: docker
#       AUTHOR:  Philippe LEAL
#      VERSION: 2.3
#      CREATED: 2025-10-02
#===============================================================================

set -uo pipefail

DOCKER="$(command -v docker)"

#===============================================================================
# Docker network subnets
#===============================================================================

echo "# HELP docker_network_subnet Subnet used by Docker networks"
echo "# TYPE docker_network_subnet gauge"

network_ids=$("$DOCKER" network ls -q 2>/dev/null || true)

if [[ -n "$network_ids" ]]; then
    "$DOCKER" network inspect $network_ids \
        --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' \
        2>/dev/null |
    while read -r name subnet; do
        [[ -n "$subnet" ]] || continue
        printf 'docker_network_subnet{network="%s",subnet="%s"} 1\n' \
            "$name" "$subnet"
    done
fi

#===============================================================================
# Global Docker logging driver
#===============================================================================

echo "# HELP docker_global_log_driver Docker global logging driver"
echo "# TYPE docker_global_log_driver gauge"

global_driver=$(
    "$DOCKER" info --format '{{.LoggingDriver}}' 2>/dev/null || true
)
global_driver="${global_driver:-unknown}"

printf 'docker_global_log_driver{driver="%s"} 1\n' "$global_driver"

#===============================================================================
# Container metrics
#===============================================================================

echo "# HELP docker_container_restart_policy Restart policy of Docker containers (0=none, 1=always, 2=unless-stopped, 3=on-failure)"
echo "# TYPE docker_container_restart_policy gauge"

echo "# HELP docker_container_log_driver Logging driver used by Docker containers"
echo "# TYPE docker_container_log_driver gauge"

echo "# HELP docker_container_image_exists_local Whether the image used by the container exists locally (1=yes, 0=no)"
echo "# TYPE docker_container_image_exists_local gauge"

echo "# HELP docker_container_image_exists_remote Whether the image used by the container exists remotely (1=yes, 0=no)"
echo "# TYPE docker_container_image_exists_remote gauge"

echo "# HELP docker_container_status 1=running, 0=stopped/exited"
echo "# TYPE docker_container_status gauge"

#===============================================================================
# Get all containers once
#===============================================================================

container_ids=$("$DOCKER" ps -aq 2>/dev/null || true)

total=0

declare -A image_local=()
declare -A image_remote=()
declare -A images=()

if [[ -n "$container_ids" ]]; then

    #===========================================================================
    # One Docker inspect for ALL containers
    #===========================================================================

    containers=$(
        "$DOCKER" inspect $container_ids \
            --format '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.LogConfig.Type}}|{{.Config.Image}}|{{.State.Status}}' \
            2>/dev/null || true
    )

    #===========================================================================
    # First pass:
    #   - output container information
    #   - collect unique images
    #===========================================================================

    while IFS='|' read -r cname policy driver image state; do

        [[ -n "$cname" ]] || continue

        cname="${cname#/}"

        total=$((total + 1))

        #-----------------------------------------------------------------------
        # Restart policy
        #-----------------------------------------------------------------------

        case "$policy" in
            ""|no)
                value=0
                policy_label="none"
                ;;
            always)
                value=1
                policy_label="always"
                ;;
            unless-stopped)
                value=2
                policy_label="unless-stopped"
                ;;
            on-failure)
                value=3
                policy_label="on-failure"
                ;;
            *)
                value=-1
                policy_label="$policy"
                ;;
        esac

        printf \
            'docker_container_restart_policy{container="%s",policy="%s"} %s\n' \
            "$cname" "$policy_label" "$value"

        #-----------------------------------------------------------------------
        # Log driver
        #-----------------------------------------------------------------------

        driver="${driver:-none}"

        printf \
            'docker_container_log_driver{container="%s",driver="%s"} 1\n' \
            "$cname" "$driver"

        #-----------------------------------------------------------------------
        # Collect unique image
        #-----------------------------------------------------------------------

        images["$image"]=1

        #-----------------------------------------------------------------------
        # Container status
        #-----------------------------------------------------------------------

        if [[ "$state" == "running" ]]; then
            value=1
        else
            value=0
        fi

        printf \
            'docker_container_status{name="%s",state="%s"} %s\n' \
            "$cname" "$state" "$value"

    done <<< "$containers"

    #===========================================================================
    # Local image existence
    #
    # One docker image inspect per UNIQUE image.
    #===========================================================================

    for image in "${!images[@]}"; do
        if "$DOCKER" image inspect "$image" >/dev/null 2>&1; then
            image_local["$image"]=1
        else
            image_local["$image"]=0
        fi
    done

    #===========================================================================
    # Remote image existence
    #
    # Run checks in parallel.
    #
    # Each result is written to a temporary file. This avoids synchronization
    # problems between background processes.
    #===========================================================================

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    pids=()
    index=0

    for image in "${!images[@]}"; do

        result_file="$tmpdir/$index"

        (
            if "$DOCKER" manifest inspect "$image" >/dev/null 2>&1; then
                printf '1\t%s\n' "$image" > "$result_file"
            else
                printf '0\t%s\n' "$image" > "$result_file"
            fi
        ) &

        pids+=("$!")
        index=$((index + 1))

    done

    #===========================================================================
    # Wait for all remote checks
    #===========================================================================

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    #===========================================================================
    # Read remote results
    #===========================================================================

    for result_file in "$tmpdir"/*; do
        [[ -f "$result_file" ]] || continue

        IFS=$'\t' read -r value image < "$result_file"

        image_remote["$image"]="$value"
    done

    #===========================================================================
    # Output image metrics
    #
    # We need to associate each image back with its containers.
    #===========================================================================

    while IFS='|' read -r cname policy driver image state; do

        [[ -n "$cname" ]] || continue

        cname="${cname#/}"

        printf \
            'docker_container_image_exists_local{container="%s",image="%s"} %s\n' \
            "$cname" \
            "$image" \
            "${image_local[$image]:-0}"

        printf \
            'docker_container_image_exists_remote{container="%s",image="%s"} %s\n' \
            "$cname" \
            "$image" \
            "${image_remote[$image]:-0}"

    done <<< "$containers"

fi

#===============================================================================
# Container total
#===============================================================================

echo "# HELP docker_container_total Number of Docker containers (all states)"
echo "# TYPE docker_container_total gauge"
printf 'docker_container_total %s\n' "$total"
