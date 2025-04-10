#!/bin/bash

# Script pour exporter les métriques Docker vers Prometheus
# Usage : placer ce script dans un cron ou un systemd timer pour générer périodiquement le fichier

# Déclarer un tableau pour suivre les métriques déjà documentées
declare -A documented_metrics

# Fonction pour écrire les métriques dans le fichier temporaire
write_metric() {
    local name=$1
    local value=$2
    local help=$3
    local type=$4
    local labels=${5:-}

    # Écrire HELP et TYPE seulement si c'est la première occurrence de cette métrique
    if [[ -z "${documented_metrics[$name]}" ]]; then
        echo "# HELP $name $help"
        echo "# TYPE $name $type"
        documented_metrics[$name]=1
    fi

    if [ -z "$labels" ]; then
        echo "$name $value"
    else
        echo "$name$labels $value"
    fi
}

# 1. Total CPU utilisé par Docker (en pourcentage)
total_cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" 2>/dev/null | awk '{gsub(/%/, "", $1); sum += $1} END {print sum+0}')
write_metric "docker_cpu_total_percent" "$total_cpu" "Total CPU percentage used by all Docker containers" "gauge"

# 2. Total RAM utilisé par Docker (en pourcentage)
total_mem=$(docker stats --no-stream --format "{{.MemPerc}}" 2>/dev/null | awk '{gsub(/%/, "", $1); sum += $1} END {print sum+0}')
write_metric "docker_memory_total_percent" "$total_mem" "Total memory percentage used by all Docker containers" "gauge"

# 3. Mémoire utilisée par conteneur (en pourcentage)
containers_running=$(docker ps -q)
if [ -n "$containers_running" ]; then
    while read -r line; do
        container_id=$(echo "$line" | awk '{print $1}')
        container_name=$(echo "$line" | awk '{print $2}')
        mem_perc=$(echo "$line" | awk '{gsub(/%/, "", $3); print $3}')
        
        write_metric "docker_container_memory_percent" "$mem_perc" "Memory percentage used by individual container" "gauge" \
            "{container_id=\"$container_id\",container_name=\"$container_name\"}"
    done < <(docker stats --no-stream --format "{{.ID}} {{.Name}} {{.MemPerc}}")
fi

# 4. Nombre total de containers
container_count=$(docker ps -a --format "{{.ID}}" | wc -l)
write_metric "docker_containers_total" "$container_count" "Total number of Docker containers" "gauge"

# 5. Conteneurs exited - version globale
exited_total_count=$(docker ps -a --filter "status=exited" --format "{{.ID}}" | wc -l)
write_metric "docker_containers_total_exited" "$exited_total_count" "Total number of Docker containers in exited state" "gauge"

# 6. Status exited par conteneur (utilise maintenant une vérification "contient Exited")
while read -r line; do
    container_id=$(echo "$line" | awk '{print $1}')
    container_name=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')
    
    if [[ "$status" == *"Exited"* ]]; then
        write_metric "docker_container_exited" "0" "Docker container exited status (1 if exited)" "gauge" \
            "{container_id=\"$container_id\",container_name=\"$container_name\"}"
    fi
done < <(docker ps -a --format "{{.ID}} {{.Names}} {{.Status}}")

# 7. Conteneurs unhealthy - version globale
unhealthy_total_count=$(docker ps -a --filter "health=unhealthy" --format "{{.ID}}" | wc -l)
write_metric "docker_containers_total_unhealthy" "$unhealthy_total_count" "Total number of Docker containers with unhealthy status" "gauge"

# 8. Status unhealthy par conteneur
while read -r line; do
    container_id=$(echo "$line" | awk '{print $1}')
    container_name=$(echo "$line" | awk '{print $2}')
    health_status=$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null)
    
    if [[ "$health_status" == *"unhealthy"* ]]; then
        write_metric "docker_container_unhealthy" "0" "Docker container unhealthy status (1 if unhealthy)" "gauge" \
            "{container_id=\"$container_id\",container_name=\"$container_name\"}"
    fi
done < <(docker ps -a --format "{{.ID}} {{.Names}} {{.Status}}")
