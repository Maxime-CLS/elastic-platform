#!/bin/bash -eu
set -o pipefail

ipvar="0.0.0.0"

declare COMPOSE

# Ignore following warning
# shellcheck disable=SC1091
. .env

HEADERS=(
  -H "kbn-version: ${STACK_VERSION}"
  -H "kbn-xsrf: kibana"
  -H 'Content-Type: application/json'
)

# Create the script usage menu
usage() {
  cat <<EOF | sed -e 's/^  //'
  usage: ./elastic-container.sh [-v] (stage|start|stop|restart|status|help)
  actions:
    stage     downloads all necessary images to local storage
    start     creates a container network and starts containers
    stop      stops running containers without removing them
    destroy   stops and removes the containers, the network, and volumes created
    restart   restarts all the stack containers
    status    check the status of the stack containers
    clear     clear all documents in logs and metrics indexes
    help      print this message
  flags:
    -v        enable verbose output
EOF
}

get_host_ip() {
  os=$(uname -s)
  if [ "${os}" == "Linux" ]; then
    ipvar=$(hostname -I | awk '{ print $1}')
  elif [ "${os}" == "Darwin" ]; then
    ipvar=$(ifconfig en0 | awk '$1 == "inet" {print $2}')
  fi
}

set_fleet_values() {
  # Get the current Fleet settings
  CURRENT_SETTINGS=$(curl -k -s -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X GET "${LOCAL_KBN_URL}/api/fleet/agents/setup" -H "Content-Type: application/json")

  # Check if Fleet is already set up
  if echo "$CURRENT_SETTINGS" | grep -q '"isInitialized": true'; then
    echo "Fleet settings are already configured."
    return
  fi

  echo "Fleet is not initialized, setting up Fleet..."
  
  fingerprint=$(${COMPOSE} exec -w /usr/share/elasticsearch/config/certs/ca elasticsearch cat ca.crt | openssl x509 -noout -fingerprint -sha256 | cut -d "=" -f 2 | tr -d :)
  printf '{"host": "%s", "name": "Elastic Artifacts", "is_default": true}' "https://package-registry/downloads/" | curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/agent_download_sources/fleet-default-download-source" -d @- | jq
  printf '{"fleet_server_hosts": ["%s"]}' "https://fleet-server:${FLEET_PORT}" | curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/settings" -d @- | jq
  printf '{"hosts": ["%s"]}' "https://elasticsearch:9200" | curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq
  printf '{"ca_trusted_fingerprint": "%s"}' "${fingerprint}" | curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq
  printf '{"config_yaml": "%s"}' "ssl.verification_mode: certificate" | curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -XPUT "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq
}

set_synthetics_monitor() {
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/private_locations" --data '{ "label": "localhost", "agentPolicyId": "default-policy", "tags": ["private"]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "http", "name": "Nginx Availability", "url": "http://nginx:8081", "tags": ["nginx", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "http", "name": "Backend Availability", "url": "http://petclinic:8080", "tags": ["backend", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "tcp", "name": "DataBase Availability", "host": "tcp://mysql:3306", "tags": ["database", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "browser", "name": "Home -> Show Vets journey", "inline_script": "step(\"load homepage\", async () => { await page.goto(\"http://'${ipvar}':8081/\"); await page.waitForRequest(/intake/); }); step(\"click on vets\", async () => { await page.click(\"#main-navbar > ul > li:nth-child(4) > a\"); await page.waitForRequest(/intake/); });", "tags": ["user_journeys", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "browser", "name": "Home -> Add Owner journey", "inline_script": "step(\"load homepage\", async () => { await page.goto(\"http://'${ipvar}':8081/\"); await page.waitForRequest(/intake/); }); step(\"click on find owners\", async () => { await page.click(\"#main-navbar > ul > li:nth-child(3) > a\"); await page.waitForRequest(/intake/); }); step(\"click on add Owner button\", async () => { await page.click(\"body > div.container-fluid > div > a\"); await page.waitForRequest(/intake/); });", "tags": ["user_journeys", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
  curl -k --silent --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X POST "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/synthetics/monitors" --data '{ "type": "browser", "name": "Home -> Home -> Error journey", "inline_script": "step(\"load homepage\", async () => { await page.goto(\"http://'${ipvar}':8081/\"); await page.waitForRequest(/intake/); }); step(\"click on error\", async () => { await page.click(\"#main-navbar > ul > li:nth-child(5) > a\"); await page.waitForRequest(/intake/); });", "tags": ["user_journeys", "availability"], "locations": [{"id":"default-policy","label":"localhost"}]}'
}

clear_documents() {
  if (($(curl -k --silent "${HEADERS[@]}" --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X DELETE "https://${ipvar}:9200/_data_stream/logs-*" | grep -c "true") > 0)); then
    printf "Successfully cleared logs data stream"
  else
    printf "Failed to clear logs data stream"
  fi
  echo
  if (($(curl -k --silent "${HEADERS[@]}" --user "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" -X DELETE "https://${ipvar}:9200/_data_stream/metrics-*" | grep -c "true") > 0)); then
    printf "Successfully cleared metrics data stream"
  else
    printf "Failed to clear metrics data stream"
  fi
  echo
}

# Logic to enable the verbose output if needed
OPTIND=1 # Reset in case getopts has been used previously in the shell.

verbose=0

while getopts "v" opt; do
  case "$opt" in
  v)
    verbose=1
    ;;
  *) ;;
  esac
done

shift $((OPTIND - 1))

[ "${1:-}" = "--" ] && shift

ACTION="${*:-help}"

if [ $verbose -eq 1 ]; then
  exec 3<>/dev/stderr
else
  exec 3<>/dev/null
fi

if docker compose >/dev/null; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null; then
  COMPOSE="docker-compose"
else
  echo "elastic-container requires docker compose!"
  exit 2
fi

case "${ACTION}" in

"stage")
  # Collect the Elastic, Kibana, and Elastic-Agent Docker images
  docker pull "docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}"
  docker pull "docker.elastic.co/kibana/kibana:${STACK_VERSION}"
  docker pull "docker.elastic.co/beats/elastic-agent-complete:${STACK_VERSION}"
  docker pull "docker.elastic.co/package-registry/distribution:${STACK_VERSION}"
  ;;

"start")

  get_host_ip

  echo "Starting Elastic Stack network and containers."

  ${COMPOSE} up -d --no-deps 

  echo "Waiting 40 seconds for Fleet Server setup."
  echo

  sleep 40

  echo "Populating Fleet Settings."
  set_fleet_values > /dev/null 2>&1
  echo

  echo "Populating Synthetic Monitor."
  set_synthetics_monitor > /dev/null 2>&1
  echo
  
  echo "READY SET GO!"
  echo
  echo "Browse to https://localhost:${KIBANA_PORT}"
  echo "Username: ${ELASTIC_USERNAME}"
  echo "Passphrase: ${ELASTIC_PASSWORD}"
  echo
  ;;

"stop")
  echo "Stopping running containers."

  ${COMPOSE} stop 
  ;;

"destroy")
  echo "#####"
  echo "Stopping and removing the containers, network, and volumes created."
  echo "#####"
  ${COMPOSE} down -v
  ;;

"restart")
  echo "#####"
  echo "Restarting all Elastic Stack components."
  echo "#####"
  ${COMPOSE} restart es01 kibana fleet-server
  ;;

"status")
  ${COMPOSE} ps | grep -v setup
  ;;

"clear")
  clear_documents
  ;;

"help")
  usage
  ;;

*)
  echo -e "Proper syntax not used. See the usage\n"
  usage
  ;;
esac

exec 3>&-