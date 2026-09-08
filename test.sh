#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

# Usage: ./test.sh ss|ws|all
[[ " ss ws all " == *" ${1:-} "* ]] && test -n "${1:-}" || { echo "Usage: ${0} ss|ws|all"; exit 1; }
CHANNELS=" ${1} " && test "${1}" != all || CHANNELS=" ss ws "
CONTAINERS="gateway"
[[ "${CHANNELS}" != *" ss "* ]] || CONTAINERS+=" shadowsocks-ss"
[[ "${CHANNELS}" != *" ws "* ]] || CONTAINERS+=" shadowsocks-ws"
ROOT="/opt/vpn-gateway"
ENV="$(dirname "$0")/test.env"
LOG="$(dirname "$0")/test.log"
touch "${ENV}" "${LOG}" && chmod 600 "${ENV}" "${LOG}"
exec > >(tee "${LOG}") 2>&1

#---------
# Settings
#---------

# Ask for missing settings once and keep them
function setting() {
  test -e "${ENV}" && source "${ENV}"
  test -n "${!1-}" && return 0
  read -r -p "${2}: " "${1}" || { echo "${2} is not specified"; exit 1; }
  echo "${1}='${!1}'" >>"${ENV}"
}
setting VM    "Virtual machine as user@host"
setting TOKEN "NordVPN token"
[[ "${CHANNELS}" != *" ws "* ]] || setting DOMAIN "Domain of the virtual machine"
SSH=(ssh -o StrictHostKeyChecking=accept-new "${VM}")

#-------------
# Installation
#-------------

# Answer the questions of the installer (Y/N are keys, the rest are lines)
[[ "${CHANNELS}" == *" ws "* ]] && answers="N${DOMAIN}"$'\n' || answers="Y"
[[ "${CHANNELS}" == *" ss "* ]] && answers+="YN" || answers+="N"
[[ "${CHANNELS}" != *" ws "* ]] || answers+="YNN"
answers+="${TOKEN}"$'\n'"N"
# Install this tool from scratch
scp -o StrictHostKeyChecking=accept-new "$(dirname "$0")/install.sh" "${VM}:/tmp/install.sh"
"${SSH[@]}" sudo bash -s <<EOL
  timeout 120s docker exec gateway nordvpn logout --persist-token >/dev/null 2>&1
  docker rm --force gateway shadowsocks-ss shadowsocks-ws >/dev/null 2>&1
  docker volume rm --force gateway >/dev/null 2>&1
  rm --recursive --force ${ROOT}/settings ${ROOT}/guide.txt
EOL
"${SSH[@]}" 'trap "rm -f /tmp/install.sh" EXIT; sudo env TERM=xterm bash -c "$(cat /tmp/install.sh)"' <<<"${answers}"

#-------
# Checks
#-------

# The containers are up, healthy and not restarting
function check_containers() {
  "${SSH[@]}" sudo bash -s <<EOL
  for i in \$(seq 1 18); do
    test "\$(docker inspect --format '{{.State.Health.Status}}' gateway 2>/dev/null)" = "healthy" && break
    sleep 10
  done
  docker ps --all --format 'table {{.Names}}\t{{.Status}}'
  for id in ${CONTAINERS}; do
    test "\$(docker inspect --format '{{.State.Running}} {{.RestartCount}}' "\${id}" 2>/dev/null)" = "true 0" ||
      { echo "FAIL: \${id} is down or restarting"; docker logs --tail 20 "\${id}"; exit 1; }
  done
  test "\$(docker inspect --format '{{.State.Health.Status}}' gateway)" = "healthy" ||
    { echo "FAIL: the tunnel is not healthy"; docker logs --tail 20 gateway; exit 1; }
  tail -n 3 /var/log/vpn-gateway.log
  echo "OK: containers"
EOL
}
# Shadowsocks leads to Internet through the tunnel
function check_ss() {
  "${SSH[@]}" sudo bash -s <<EOL
  url=\$(grep -o 'ss://[^ ]*' ${ROOT}/guide.txt | head -n 1 | sed 's|@[^:]*:|@127.0.0.1:|; s|/?prefix=[^#]*||')
  docker rm --force sslocal >/dev/null 2>&1
  docker run --rm --detach --name sslocal --net host ghcr.io/shadowsocks/sslocal-rust:latest \
    sslocal --server-url "\${url}" --local-addr 127.0.0.1:1080 >/dev/null
  sleep 3
  answer=\$(curl -4 -s -m 15 --socks5-hostname 127.0.0.1:1080 https://api.nordvpn.com/v1/helpers/ips/insights)
  docker rm --force sslocal >/dev/null
  echo "\${answer}" | grep --quiet '"protected":true' && echo "OK: ss" ||
    { echo "FAIL: ss \${answer}"; exit 1; }
EOL
}
# Shadowsocks-over-WebSockets serves the key over HTTPS
function check_ws() {
  "${SSH[@]}" sudo bash -s <<EOL
  source ${ROOT}/settings/shadowsocks-ws
  for i in \$(seq 1 12); do
    curl -fsS -m 15 "https://${DOMAIN}/\${key_path}" 2>/dev/null | grep --quiet '^transport:' &&
      echo "OK: ws" && exit 0
    sleep 10
  done
  echo "FAIL: ws" && docker logs --tail 20 shadowsocks-ws && exit 1
EOL
}
function check_channels() {
  check_containers
  [[ "${CHANNELS}" != *" ss "* ]] || check_ss
  [[ "${CHANNELS}" != *" ws "* ]] || check_ws
}
check_channels
# The channels survive a restart of NordVPN (the watcher reconnects them within a minute)
"${SSH[@]}" sudo docker restart gateway >/dev/null && sleep 75
check_channels
"${SSH[@]}" sudo docker image rm --force ghcr.io/shadowsocks/sslocal-rust:latest >/dev/null 2>&1
echo "OK: all"
