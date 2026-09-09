#!/usr/bin/env bash
#===============================================================================
#         FILE:  docker_containers_checks.sh
#
#        USAGE:  ./docker_containers_checks.sh
#
#  DESCRIPTION: Docker container runtime metrics for Prometheus.
#
#  REQUIREMENTS: docker
#       AUTHOR:  Philippe LEAL
#      VERSION: 2.1
#      CREATED: 2025-10-02
#===============================================================================

set -uo pipefail

DOCKER="$(command -v docker)"

#===============================================================================
# Prometheus helpers
#===============================================================================

declare -A documented_metrics=()

write_metric() {
    local name="$1"
    local value="$2"
    local help="$3"
    local type="$4"
    local labels="${5:-}"

    if [[ -z "${documented_metrics[$name]:-}" ]]; then
        printf '# HELP %s %s\n' "$name" "$help"
        printf '# TYPE %s %s\n' "$name" "$type"
        documented_metrics["$name"]=1
    fi

    if [[ -n "$labels" ]]; then
        printf '%s%s %s\n' "$name" "$labels" "$value"
    else
        printf '%s %s\n' "$name" "$value"
    fi
}

#===============================================================================
# Docker stats
#
# ONE docker stats call.
#===============================================================================

stats=$(
    "$DOCKER" stats --no-stream \
        --format '{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' \
        2>/dev/null || true
)

# Calculate CPU and memory totals with ONE awk call.
if [[ -n "$stats" ]]; then
    read -r total_cpu total_mem < <(
        printf '%s\n' "$stats" |
            awk -F'|' '
                {
                    cpu=$3
                    mem=$4

                    sub(/%$/, "", cpu)
                    sub(/%$/, "", mem)

                    cpu_total += cpu
                    mem_total += mem
                }
                END {
                    printf "%.2f %.2f\n", cpu_total+0, mem_total+0
                }
            '
    )
else
    total_cpu="0.00"
    total_mem="0.00"
fi

write_metric \
    "docker_cpu_total_percent" \
    "$total_cpu" \
    "Total CPU percentage used by all Docker containers" \
    "gauge"

write_metric \
    "docker_memory_total_percent" \
    "$total_mem" \
    "Total memory percentage used by all Docker containers" \
    "gauge"

#===============================================================================
# Per-container memory
#===============================================================================

if [[ -n "$stats" ]]; then
    while IFS='|' read -r container_id container_name cpu_perc mem_perc; do

        [[ -n "$container_id" ]] || continue

        mem_perc="${mem_perc%\%}"

        write_metric \
            "docker_container_memory_percent" \
            "$mem_perc" \
            "Memory percentage used by individual container" \
            "gauge" \
            "{container_id=\"$container_id\",container_name=\"$container_name\"}"

    done <<< "$stats"
fi

#===============================================================================
# Get all containers
#===============================================================================

containers=$(
    "$DOCKER" ps -a \
        --format '{{.ID}}|{{.Names}}|{{.Status}}' \
        2>/dev/null || true
)

container_count=0
exited_count=0

if [[ -n "$containers" ]]; then
    read -r container_count exited_count < <(
        printf '%s\n' "$containers" |
            awk -F'|' '
                NF {
                    total++
                    if ($3 ~ /^Exited/) {
                        exited++
                    }
                }
                END {
                    printf "%d %d\n", total+0, exited+0
                }
            '
    )
fi

write_metric \
    "docker_containers_total" \
    "$container_count" \
    "Total number of Docker containers" \
    "gauge"

write_metric \
    "docker_containers_total_exited" \
    "$exited_count" \
    "Total number of Docker containers in exited state" \
    "gauge"

#===============================================================================
# Inspect all containers once
#
# Retrieves health status for every container with a single docker inspect.
#===============================================================================

health_data=""

if [[ -n "$containers" ]]; then

    container_ids=$(
        printf '%s\n' "$containers" |
            awk -F'|' 'NF { print $1 }'
    )

    health_data=$(
        "$DOCKER" inspect $container_ids \
            --format '{{.Id}}|{{.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            2>/dev/null || true
    )

fi

#===============================================================================
# Exited container metrics
#===============================================================================

if [[ -n "$containers" ]]; then

    while IFS='|' read -r container_id container_name status; do

        [[ -n "$container_id" ]] || continue

        if [[ "$status" == Exited* ]]; then
            write_metric \
                "docker_container_exited" \
                "0" \
                "Docker container exited status (1 if exited)" \
                "gauge" \
                "{container_id=\"$container_id\",container_name=\"$container_name\"}"
        fi

    done <<< "$containers"

fi

#===============================================================================
# Unhealthy container metrics
#===============================================================================

unhealthy_count=0

if [[ -n "$health_data" ]]; then

    while IFS='|' read -r container_id container_name health_status; do

        [[ -n "$container_id" ]] || continue

        if [[ "$health_status" == "unhealthy" ]]; then

            unhealthy_count=$((unhealthy_count + 1))

            write_metric \
                "docker_container_unhealthy" \
                "0" \
                "Docker container unhealthy status (1 if unhealthy)" \
                "gauge" \
                "{container_id=\"$container_id\",container_name=\"$container_name\"}"
        fi

    done <<< "$health_data"

fi

write_metric \
    "docker_containers_total_unhealthy" \
    "$unhealthy_count" \
    "Total number of Docker containers with unhealthy status" \
    "gauge"
