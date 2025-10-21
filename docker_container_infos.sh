#!/usr/bin/env bash
set -euo pipefail

# Output file for node_exporter's textfile collector
OUTPUT="/var/lib/node_exporter/docker_container_infos.prom"
TMP_OUTPUT="$(mktemp)"

# --------------------------
# Docker network subnets
# --------------------------
echo "# HELP docker_network_subnet Subnet used by Docker networks" > "$TMP_OUTPUT"
echo "# TYPE docker_network_subnet gauge" >> "$TMP_OUTPUT"

docker network inspect $(docker network ls -q) \
  --format '{{ .Name }} {{ range .IPAM.Config }}{{ .Subnet }}{{ end }}' |
while read -r name subnet; do
  if [[ -n "$subnet" ]]; then
    echo "docker_network_subnet{network=\"${name}\",subnet=\"${subnet}\"} 1" >> "$TMP_OUTPUT"
  fi
done

# --------------------------
# Docker container restart policies
# --------------------------
echo "# HELP docker_container_restart_policy Restart policy of Docker containers (0=none, 1=always, 2=unless-stopped, 3=on-failure)" >> "$TMP_OUTPUT"
echo "# TYPE docker_container_restart_policy gauge" >> "$TMP_OUTPUT"

docker inspect $(docker ps -aq) \
  --format '{{ .Name }} {{ .HostConfig.RestartPolicy.Name }}' |
while read -r cname policy; do
  case "$policy" in
    "") value=0 ;;
    "no") value=0 ;;
    "always") value=1 ;;
    "unless-stopped") value=2 ;;
    "on-failure") value=3 ;;
    *) value=-1 ;;
  esac
  echo "docker_container_restart_policy{container=\"${cname}\",policy=\"${policy:-none}\"} ${value}" >> "$TMP_OUTPUT"
done

# --------------------------
# Docker container log drivers
# --------------------------
echo "# HELP docker_container_log_driver Logging driver used by Docker containers" >> "$TMP_OUTPUT"
echo "# TYPE docker_container_log_driver gauge" >> "$TMP_OUTPUT"

docker inspect $(docker ps -aq) \
  --format '{{ .Name }} {{ .HostConfig.LogConfig.Type }}' |
while read -r cname driver; do
  driver="${driver:-none}"
  echo "docker_container_log_driver{container=\"${cname}\",driver=\"${driver}\"} 1" >> "$TMP_OUTPUT"
done

# --------------------------
# Docker container image existence (local + remote)
# --------------------------
echo "# HELP docker_container_image_exists_local Whether the image used by the container exists locally (1=yes, 0=no)" >> "$TMP_OUTPUT"
echo "# TYPE docker_container_image_exists_local gauge" >> "$TMP_OUTPUT"

echo "# HELP docker_container_image_exists_remote Whether the image used by the container exists remotely (1=yes, 0=no)" >> "$TMP_OUTPUT"
echo "# TYPE docker_container_image_exists_remote gauge" >> "$TMP_OUTPUT"

docker inspect $(docker ps -aq) \
  --format '{{ .Name }} {{ .Config.Image }}' |
while read -r cname image; do
  # Local check
  if docker image inspect "$image" >/dev/null 2>&1; then
    local_value=1
  else
    local_value=0
  fi
  echo "docker_container_image_exists_local{container=\"${cname}\",image=\"${image}\"} ${local_value}" >> "$TMP_OUTPUT"

  # Remote check
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    remote_value=1
  else
    remote_value=0
  fi
  echo "docker_container_image_exists_remote{container=\"${cname}\",image=\"${image}\"} ${remote_value}" >> "$TMP_OUTPUT"
done

# --------------------------
# Finish
# --------------------------
mv "$TMP_OUTPUT" "$OUTPUT"

