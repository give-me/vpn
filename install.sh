#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

TITLE="vpn-gateway"
ROOT="/opt/${TITLE}"
LOG="/var/log/${TITLE}.log"
TASK_TO_START="${ROOT}/bin/start.sh"
TASK_TO_WATCH="${ROOT}/bin/watch.sh"
TASK_TO_REINSTALL="${ROOT}/bin/reinstall.sh"
TASK_TO_UNINSTALL="${ROOT}/bin/uninstall.sh"
declare GUIDE
declare PUBLIC
declare REMOVE_REQUIREMENTS
declare REMOVE_INSTRUCTIONS
PUBLISH=()
ALLOW_TCP=()
ALLOW_UDP=()
CIPHER="chacha20-ietf-poly1305"
YQ_IMAGE="mikefarah/yq:4" # specified for stability
SS_IMAGE="ghcr.io/shadowsocks/ssserver-rust:latest"
WS_IMAGE="ghcr.io/give-me/outlinecaddy:latest"
NV_IMAGE="${TITLE}/nordvpn"
SS_ID="shadowsocks-ss"
WS_ID="shadowsocks-ws"
NV_ID="gateway"


#############################
###   Helping functions   ###
#############################

#---------------------
# Messages and dialogs
#---------------------

function style() {
  local msg && msg="$(tput setaf "${1}")${2}"
  test -z "${3-}" || msg+=" $(tput bold)${3}"
  echo -e -n "${msg}$(tput sgr0)"
}

function ask() {
  style 6 "${1} "
}

function info() {
  style 2 "${1}" "${2-}"
}

function error() {
  style 1 "${1}" "${2-}"
  exit 1
}

function prompt() {
  while :; do
    ask "${1} [and press Enter]:"
    read -r || error "There is no input\n"
    test -z "${REPLY}" || return 0
  done
}

function confirm() {
  while :; do
    ask "${1} [Y/N]"
    read -r -s -n 1 || error "There is no input\n"
    [[ "${REPLY}" =~ ^[yY]$ ]] && echo "Y" && sleep 1 && return 0
    [[ "${REPLY}" =~ ^[nN]$ ]] && echo "N" && sleep 1 && return 1
    style 1 "${REPLY} is a wrong answer\n"
  done
}

function choose() {
  style 6 "${1} [and press Enter]:\n" && shift 1
  # Find choices and notes
  local i=0 && local choices=() && local notes=() && while [[ $# -gt 0 ]]; do
    choices[i]="${1}" && notes[i]="${2}" && i=$((i+1)) && shift 2
  done
  # Create a temporary associative array for mapping
  local -A mapping=() && for i in "${!notes[@]}"; do
    mapping["${notes[i]}"]="${choices[i]}"
  done
  # Ask for a choice
  local note && select note in "${notes[@]}"; do
    test -n "${note}" && REPLY="${mapping[$note]}" && break
    style 1 "${REPLY} is a wrong answer\n"
  done
  test -n "${note}" || error "There is no input\n"
}

#----------------
# Other functions
#----------------

function command_exists {
  command -v "$@" >/dev/null 2>&1
}

function install_docker() {
  if ! command_exists docker; then
    info "Install Docker\n"
    curl -fsSL https://get.docker.com | sh
  fi
}

function latest_version() {
  curl -s "https://hub.docker.com/v2/repositories/library/${1}/tags/?page_size=100" | \
    yq --unwrapScalar=true '.results[] | select(.name | test("^[.0-9]+$")) | .name' | \
    sort --version-sort | tail --lines=1
}

function generate_port() {
  local port && while port=$((1024 + RANDOM % 31744)) &&
    { grep -qs "=${port}$" "${ROOT}"/settings/* || [[ " $* " == *" ${port} "* ]]; }; do :; done
  echo "${port}"
}

function generate_rand() {
  local length=50
  openssl rand -base64 ${length} | tr -dc 'A-Za-z0-9' | head -c ${length}
}

function nordvpn() {
  docker run --rm \
    --cap-add NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 \
    --volume "${NV_ID}:/var/lib/nordvpn" \
    --volume "${TASK_TO_START}:/start.sh:ro" \
    "${NV_IMAGE}" "$@"
}

################################
###   Setting up this tool   ###
################################

#--------------------
# Checks and analysis
#--------------------

# Check permissions and a terminal
test $EUID -eq 0 || error "This tool should be executed by root only"
export TERM="${TERM:-xterm}" && tput colors >/dev/null 2>&1 || export TERM=xterm
# Get details of a main interface
DEV=$(ip route show default | head -n 1 | awk '{print $5}')
IP=$(ip -oneline route get '1.1.1.1' oif "${DEV}" | grep -o 'src [^ ]*' | cut -d ' ' -f 2)
# Extend the guide
GUIDE+="$(info "Interface ${DEV} was detected as default with IP:" "${IP}")\n\n"

#------------------------
# Installing dependencies
#------------------------

install_docker && docker pull "${YQ_IMAGE}"
command_exists crontab || apt-get install -y cron

function yq() {
  docker run --rm --interactive --network none "${YQ_IMAGE}" "$@"
}

#----------------------
# Preparing file system
#----------------------

mkdir --parents ${ROOT}/{bin,settings,data} && chmod 700 "${ROOT}"

############################
###   General settings   ###
############################

#---------------------------
# Public IP or a domain name
#---------------------------

clear -x
test -e "${ROOT}/settings/public" && recent="$(cat "${ROOT}/settings/public")" &&
  confirm "Should ${recent} be used to access this server (was specified before)" &&
  PUBLIC="${recent}" || rm --force "${ROOT}/settings/public"
test -z "${PUBLIC-}" &&
  confirm "Should ${IP} be used to access this server (was found for ${DEV})" &&
  PUBLIC="${IP}"
while test -z "${PUBLIC-}"; do
  prompt "Specify another domain or IP to access this server" &&
    PUBLIC="${REPLY}" && echo "${PUBLIC}" >"${ROOT}/settings/public" || :
done

######################################
###   Configuring input channels   ###
######################################

REMOVE_REQUIREMENTS+="
$(declare -f command_exists)"

#----------------------------------------
# Shadowsocks (traffic masking available)
#----------------------------------------

remove="
  # Shadowsocks
  command_exists docker && docker rm --force ${SS_ID} >/dev/null 2>&1
  rm --force ${ROOT}/settings/${SS_ID}
  rm --force ${ROOT}/data/${SS_ID}.json"
REMOVE_INSTRUCTIONS+="${remove}"
clear -x
if confirm "Should this server be accessible via Shadowsocks?"; then
  docker pull "${SS_IMAGE}"
  # Generate missing settings and load the settings
  if test ! -e "${ROOT}/settings/${SS_ID}"; then
    settings="secret='$(generate_rand)'\n"
    if confirm "Would you like to make the connection look like an allowed protocol?"; then
      choose "Choose an allowed protocol to emulate" \
        "POST%20"                  "HTTP request (80 – http)" \
        "HTTP%2F1.1%20"            "HTTP response (80 – http)" \
        "%05%C3%9C_%C3%A0%01%20"   "DNS-over-TCP request (53 – dns)" \
        "SSH-2.0%0D%0A"            "SSH (22 – ssh, 830 – netconf-ssh, 4334 – netconf-ch-ssh, 5162 – snmpssh-trap)" \
        "%16%03%01%00%C2%A8%01%01" "TLS ClientHello (443 – https, 463 – smtps, 563 – nntps, 636 – ldaps, 989 – ftps-data, 990 – ftps, 993 – imaps, 995 – pop3s, 5223 – Apple APN, 5228 – Play Store, 5349 – turns)" \
        "%16%03%03%40%00%02"       "TLS ServerHello (443 – https, 463 – smtps, 563 – nntps, 636 – ldaps, 989 – ftps-data, 990 – ftps, 993 – imaps, 995 – pop3s, 5223 – Apple APN, 5228 – Play Store, 5349 – turns)" \
        "%13%03%03%3F"             "TLS Application Data (443 – https, 463 – smtps, 563 – nntps, 636 – ldaps, 989 – ftps-data, 990 – ftps, 993 – imaps, 995 – pop3s, 5223 – Apple APN, 5228 – Play Store, 5349 – turns)"
      settings+="prefix='${REPLY}'\n"
      while prompt "Specify a port" && ! { [[ "${REPLY}" =~ ^[0-9]{1,5}$ ]] && test "${REPLY}" -ge 1 -a "${REPLY}" -le 65535; }; do
        style 1 "${REPLY} is a wrong port\n"
      done
      settings+="port=${REPLY}\n"
    else
      settings+="port=$(generate_port)\n"
    fi
    settings+="server_port=$(generate_port)"
    echo -e "${settings}" >"${ROOT}/settings/${SS_ID}"
  fi
  source "${ROOT}/settings/${SS_ID}"
  # Create a config
  config="server: 0.0.0.0\n"
  config+="server_port: ${server_port}\n"
  config+="password: ${secret}\n"
  config+="method: ${CIPHER}\n"
  config+="mode: tcp_and_udp"
  echo -e "${config}" | yq --output-format json >"${ROOT}/data/${SS_ID}.json"
  # Add ports to publish and allow
  PUBLISH+=("${port}:${server_port}/tcp" "${port}:${server_port}/udp")
  ALLOW_TCP+=("${server_port}")
  ALLOW_UDP+=("${server_port}")
  # Extend the guide
  userinfo="${CIPHER}:${secret}"
  userinfo="$(echo -n "${userinfo}" | base64 --wrap=0 | tr -d '=')"
  url="ss://${userinfo}@${PUBLIC}:${port}"
  test -n "${prefix+x}" && url+="/?prefix=${prefix}"
  url+="#${TITLE}"
  GUIDE+="$(info "In order to access via Shadowsocks, do the following:")\n"
  GUIDE+="$(info "1) Ensure that the port is open:" "${port} (TCP and UDP)")\n"
  GUIDE+="$(info "2) Configure Outline Client with the following URL:" "${url}")\n\n"
else eval "${remove}" || :; fi

#----------------------------
# Shadowsocks-over-WebSockets
#----------------------------

remove="
  # Shadowsocks-over-WebSockets
  command_exists docker && {
    docker rm --force ${WS_ID} >/dev/null 2>&1
    docker volume rm --force ${WS_ID} >/dev/null 2>&1
  }
  rm --force ${ROOT}/settings/${WS_ID}
  rm --force ${ROOT}/data/${WS_ID}.json"
REMOVE_INSTRUCTIONS+="${remove}"
clear -x
if ! [[ "${PUBLIC}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && test "${port-}" != 443 \
  && confirm "Should this server be accessible via Shadowsocks-over-WebSockets?"; then
  docker pull "${WS_IMAGE}"
  # Generate missing settings and load the settings
  if test ! -e "${ROOT}/settings/${WS_ID}"; then
    settings="key_path='$(generate_rand)'\n"
    settings+="tcp_path='$(generate_rand)'\n"
    settings+="udp_path='$(generate_rand)'\n"
    settings+="secret='$(generate_rand)'\n"
    https_port=$(generate_port) && http_port=$(generate_port "${https_port}")
    settings+="https_port=${https_port}\nhttp_port=${http_port}"
    echo -e "${settings}" >"${ROOT}/settings/${WS_ID}"
  fi
  source "${ROOT}/settings/${WS_ID}"
  # Create a key for Outline Client
  key="transport:\n"
  key+="  \$type: tcpudp\n"
  key+="  tcp:\n"
  key+="    \$type: shadowsocks\n"
  key+="    endpoint:\n"
  key+="      \$type: websocket\n"
  key+="      url: wss://${PUBLIC}/${tcp_path}\n"
  key+="    cipher: ${CIPHER}\n"
  key+="    secret: ${secret}\n"
  key+="  udp:\n"
  key+="    \$type: shadowsocks\n"
  key+="    endpoint:\n"
  key+="      \$type: websocket\n"
  key+="      url: wss://${PUBLIC}/${udp_path}\n"
  key+="    cipher: ${CIPHER}\n"
  key+="    secret: ${secret}"
  # Create a config for Caddy with outline
  config="admin:\n"
  config+="  disabled: true\n"
  config+="apps:\n"
  config+="  outline:\n"
  config+="    shadowsocks:\n"
  config+="      replay_history: 10000\n"
  config+="    connection_handlers:\n"
  config+="    - name: ss\n"
  config+="      handle:\n"
  config+="        handler: shadowsocks\n"
  config+="        keys:\n"
  config+="        - id: key\n"
  config+="          cipher: ${CIPHER}\n"
  config+="          secret: ${secret}\n"
  config+="  http:\n"
  config+="    https_port: ${https_port}\n"
  config+="    http_port: ${http_port}\n"
  config+="    servers:\n"
  config+="      server:\n"
  config+="        listen: [':${https_port}']\n"
  config+="        routes:\n"
  config+="        - match:\n"
  config+="          - host: ['${PUBLIC}']\n"
  config+="            path: ['/${tcp_path}']\n"
  config+="          handle:\n"
  config+="          - handler: websocket2layer4\n"
  config+="            connection_handler: ss\n"
  config+="            type: stream\n"
  config+="        - match:\n"
  config+="          - host: ['${PUBLIC}']\n"
  config+="            path: ['/${udp_path}']\n"
  config+="          handle:\n"
  config+="          - handler: websocket2layer4\n"
  config+="            connection_handler: ss\n"
  config+="            type: packet\n"
  # Add the key to the config
  config+="        - match:\n"
  config+="          - host: ['${PUBLIC}']\n"
  config+="            path: ['/${key_path}']\n"
  config+="          handle:\n"
  config+="          - handler: static_response\n"
  config+="            body: |\n"
  spaces=$(echo -e "${config}" | tail -n 2 | grep -o '^ *')
  config+="$(echo -e "${key}" | sed "s/^/${spaces}  /")\n"
  # Offer optional behavior of Caddy
  declare handle
  # – offer emulation of another web server
  if confirm "Would you like to handle bad paths at ${PUBLIC} with emulation of another web server?"; then
    # Actual trends are published here — https://w3techs.com/technologies/history_overview/web_server
    choose "Choose another web server to emulate" \
      "nginx" "Nginx" \
      "httpd" "Apache" \
      "node"  "Node.js" \
      "ls"    "LiteSpeed"
    case ${REPLY} in
      nginx)
        server="nginx/$(latest_version "nginx")"
        ;;
      httpd)
        platforms=("FreeBSD" "Unix" "Linux" "Debian" "Ubuntu" "CentOS" "Fedora" "Red Hat")
        platform=${platforms[$((RANDOM % ${#platforms[@]}))]}
        server="Apache/$(latest_version "httpd") (${platform})"
        ;;
      node)
        server="Node.js/$(latest_version "node")"
        ;;
      ls)
        server="LiteSpeed"
        ;;
    esac
    handle+="          - handler: headers\n"
    handle+="            response:\n"
    handle+="              set:\n"
    handle+="                Server: ['${server}']\n"
  fi
  # – offer a custom HTTP status code
  if confirm "Would you like to handle bad paths at ${PUBLIC} with a custom HTTP status code?"; then
    choose "Choose a custom HTTP status code" \
      301 "301 – Permanent Redirect" \
      302 "302 – Temporary Redirect" \
      401 "401 – Unauthorized" \
      403 "403 – Forbidden" \
      404 "404 – Not Found" \
      500 "500 – Server Error"
    handle+="          - handler: static_response\n"
    handle+="            status_code: ${REPLY}\n"
    if [ "${REPLY}" = 301 ] || [ "${REPLY}" = 302 ]; then
      prompt "Specify a URL to redirect to (e.g. https://example.com)"
      handle+="            headers:\n"
      handle+="              Location: [${REPLY}]\n"
    fi
  fi
  # – add optional handlers to the config
  if test -n "${handle-}"; then
    config+="        - match:\n"
    config+="          - host: ['${PUBLIC}']\n"
    config+="          handle:\n"
    config+="${handle}"
  fi
  echo -e "${config}" | yq --output-format json >"${ROOT}/data/${WS_ID}.json"
  # Add ports to publish and allow
  PUBLISH+=("443:${https_port}/tcp")
  ALLOW_TCP+=("${https_port}")
  # Extend the guide
  url="ssconf://${PUBLIC}/${key_path}#${TITLE}"
  GUIDE+="$(info "In order to access via Shadowsocks-over-WebSockets, do the following:")\n"
  GUIDE+="$(info "1) Ensure that the port is open:" "443 (TCP)")\n"
  GUIDE+="$(info "2) Configure Outline Client with the following URL:" "${url}")\n\n"
else eval "${remove}" || :; fi

#######################################
###   Configuring output channels   ###
#######################################

#--------
# NordVPN
#--------

remove="
  # NordVPN
  command_exists docker && {
    docker rm --force ${NV_ID} >/dev/null 2>&1
    nordvpn logout >/dev/null 2>&1
    docker volume rm --force ${NV_ID} >/dev/null 2>&1
    docker image rm --force ${NV_IMAGE} >/dev/null 2>&1
  }"
REMOVE_INSTRUCTIONS+="${remove}"
REMOVE_REQUIREMENTS+="
NV_ID=${NV_ID}
NV_IMAGE=${NV_IMAGE}
TASK_TO_START=${TASK_TO_START}
$(declare -f nordvpn)"
# Create a task to start NordVPN and keep the tunnel up
cat >"${TASK_TO_START}" <<'EOL'
#!/bin/bash
set -o nounset
STATUS="/run/vpn.status"
SETTINGS="/settings"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${1}"; }
status() { echo "${1} $(date +%s)" >"${STATUS}.tmp" && mv "${STATUS}.tmp" "${STATUS}"; }
nordvpn() { timeout --kill-after=5s "${TIMEOUT:-60}s" /usr/bin/nordvpn "$@" </dev/null; }
setting() { nordvpn set "$@" 2>&1 | grep --invert-match "already set" || :; }
allowlist() { nordvpn allowlist "$@" 2>/dev/null || nordvpn whitelist "$@"; }
verify() { nordvpn settings | grep --quiet "^ *${1}" || { log "Cannot apply the setting '${1}'"; exit 1; }; }

daemon_start() {
  rm --recursive --force /run/nordvpn && install --directory --mode 750 --group nordvpn /run/nordvpn
  /etc/init.d/nordvpn start >/dev/null 2>&1 || :
  local i && for i in $(seq 1 60); do
    sleep 1 && TIMEOUT=5 nordvpn version >/dev/null 2>&1 || continue
    # Answer the consent question, otherwise login waits for it
    nordvpn set analytics off >/dev/null 2>&1 || :
    return 0
  done
  return 1
}

guard() {
  # Let out of the tunnel only the traffic marked by NordVPN and no new connections to the allowed ports
  nft -f - <<EOF
add table inet gateway
add chain inet gateway output { type filter hook output priority 0; policy accept; }
add rule inet gateway output oifname != { lo, nordlynx } meta mark != 0xe1f1 drop
$(for port in ${ALLOW_TCP:-}; do echo "add rule inet gateway output oifname != { lo, nordlynx } ct direction original tcp dport ${port} drop"; done)
$(for port in ${ALLOW_UDP:-}; do echo "add rule inet gateway output oifname != { lo, nordlynx } ct direction original udp dport ${port} drop"; done)
EOF
}

configure() {
  setting fwmark 0xe1f1
  setting notify off
  setting autoconnect off
  setting technology nordlynx
  setting firewall on
  setting killswitch on
  setting dns 1.1.1.1 8.8.8.8
  allowlist remove all >/dev/null 2>&1 || :
  local port
  for port in ${ALLOW_TCP:-}; do allowlist add port "${port}" protocol TCP; done
  for port in ${ALLOW_UDP:-}; do allowlist add port "${port}" protocol UDP; done
  # Verify the settings which the guard and the channels rely on
  verify "Firewall Mark: 0xe1f1" && verify "Technology: NORDLYNX" && verify "Firewall: enabled" && verify "Kill Switch: enabled"
  for port in ${ALLOW_TCP:-}; do verify "${port} (.*TCP"; done
  for port in ${ALLOW_UDP:-}; do verify "${port} (.*UDP"; done
}

login() {
  nordvpn account >/dev/null 2>&1 && return 0
  log "Log in again"
  local token answer && source "${SETTINGS}" 2>/dev/null
  answer=$(nordvpn login --token "${token:-}" 2>&1) || { log "Cannot log in: ${answer}"; sleep 60; return 1; }
}

connect() {
  status connecting
  login || return 1
  if test -n "${GROUP:-}"; then
    TIMEOUT=120 nordvpn connect "${GROUP}" && return 0
    log "Cannot connect to ${GROUP}, try any server"
  fi
  TIMEOUT=120 nordvpn connect
}

check() {
  TIMEOUT=15 nordvpn status 2>/dev/null | grep --quiet "^Status: Connected" || return 1
  INSIGHTS=$(curl -4 -fsS -m 10 https://api.nordvpn.com/v1/helpers/ips/insights 2>/dev/null) && return 0
  INSIGHTS="" && { ping -q -c 1 -W 5 1.1.1.1 || curl -4 -fsS -m 10 -o /dev/null https://1.1.1.1; } >/dev/null 2>&1
}

rm --force "${STATUS}" && guard || { log "The guard against leaks does not work"; exit 1; }
status starting
daemon_start || { log "The NordVPN daemon does not start"; exit 1; }
# One-off commands
test "${1:-run}" = "run" || exec timeout 120s /usr/bin/nordvpn "$@"
# The service
configure
connect || log "Cannot connect, keep trying"
failures=0 && healthy=0 && leak=0
while :; do
  if check || { sleep 5 && check; }; then
    # Switch the server (not more often than every 10 minutes) while NordVPN reports the public IP as unprotected
    if [[ "${INSIGHTS//[[:space:]]/}" == *'"protected":false'* ]]; then
      healthy=0 && failures=0 && status leaking
      test $(($(date +%s) - leak)) -le 600 ||
        { log "LEAK: NordVPN reports the public IP as unprotected, switch the server"
          leak=$(date +%s) && nordvpn disconnect >/dev/null 2>&1; connect; }
      sleep 15 && continue
    fi
    test ${healthy} -eq 1 || log "The tunnel is up: $(nordvpn status | grep -E '^(Server|IP):' | tr '\n' ' ')"
    healthy=1 && failures=0 && status healthy
    sleep 15 && continue
  fi
  healthy=0 && failures=$((failures + 1)) && status unhealthy
  log "The tunnel is down (recovery attempt ${failures})"
  test ${failures} -le 4 && TIMEOUT=15 nordvpn version >/dev/null 2>&1 ||
    { log "Recovery failed, exit to let Docker restart the container"; exit 1; }
  test ${failures} -le 2 || nordvpn disconnect >/dev/null 2>&1
  connect
done
EOL
chmod +x "${TASK_TO_START}"
# Build an image with NordVPN and remove the previous one
previous=$(docker images --quiet "${NV_IMAGE}")
docker build --pull --no-cache --tag "${NV_IMAGE}" - <<'EOL'
FROM ubuntu:24.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl iputils-ping nftables && \
    curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc -o /usr/share/keyrings/nordvpn.asc && \
    echo "deb [signed-by=/usr/share/keyrings/nordvpn.asc] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
      >/etc/apt/sources.list.d/nordvpn.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nordvpn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s \
  CMD read -r state time </run/vpn.status && test "$state" = healthy && test $(($(date +%s) - time)) -lt 90
ENTRYPOINT ["/start.sh"]
EOL
docker rm --force "${NV_ID}" "${SS_ID}" "${WS_ID}" >/dev/null 2>&1 || :
test -z "${previous}" || docker image rm --force "${previous}" >/dev/null 2>&1 || :
# Log in to NordVPN and keep the token to log in again when logged out
unset token && test ! -e "${ROOT}/settings/${NV_ID}" || source "${ROOT}/settings/${NV_ID}"
clear -x
while test -z "${token-}" || ! nordvpn account >/dev/null 2>&1; do
  test -n "${token-}" || {
    info "Please, do the following:\n"
    info "1) Log you in at https://my.nordaccount.com/dashboard/nordvpn/access-tokens/\n"
    info "2) Generate new token and past the token below (non-expirable token is better)\n"
    prompt "Specify the token" && token="${REPLY}"
  }
  nordvpn login --token "${token}" || nordvpn account >/dev/null 2>&1 || unset token
done
echo "token='${token}'" >"${ROOT}/settings/${NV_ID}" && chmod 600 "${ROOT}/settings/${NV_ID}"
# Let choose a country or group as prior
clear -x
if confirm "Would you like to force NordVPN to choose a specific country?"; then
  info "Available countries:\n" && nordvpn countries
  info "Available groups:\n" && nordvpn groups
  prompt "Specify a country or group" && group="${REPLY}"
fi
# Extend the guide
GUIDE+="$(info "NordVPN has been configured:")\n"
GUIDE+="$(info "- prior country or group:" "${group:-none}")\n\n"

##############################
###   Running containers   ###
##############################

# Run NordVPN
options=()
for port in ${PUBLISH[@]+"${PUBLISH[@]}"}; do options+=(--publish "0.0.0.0:${port}"); done
docker run --detach --name "${NV_ID}" --restart always --init --tmpfs /run \
  --cap-add NET_ADMIN \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  --log-opt max-size=10m --log-opt max-file=3 \
  --env "GROUP=${group-}" \
  --env "ALLOW_TCP=${ALLOW_TCP[*]-}" \
  --env "ALLOW_UDP=${ALLOW_UDP[*]-}" \
  --volume "${NV_ID}:/var/lib/nordvpn" \
  --volume "${TASK_TO_START}:/start.sh:ro" \
  --volume "${ROOT}/settings/${NV_ID}:/settings:ro" \
  ${options[@]+"${options[@]}"} "${NV_IMAGE}"
docker inspect --format '{{.State.StartedAt}}' "${NV_ID}" >"${ROOT}/data/started"
# Run the channels when the guard against leaks is up (later they are started by the watcher only, for the same reason)
i=0 && until docker exec "${NV_ID}" test -e /run/vpn.status 2>/dev/null; do
  test $((i += 1)) -lt 30 && sleep 1 || error "The guard against leaks does not start, see 'docker logs ${NV_ID}'"
done
test ! -e "${ROOT}/data/${SS_ID}.json" ||
  docker run --detach --name "${SS_ID}" --network "container:${NV_ID}" --cap-drop NET_RAW \
    --log-opt max-size=10m --log-opt max-file=3 \
    --volume "${ROOT}/data/${SS_ID}.json:/etc/shadowsocks-rust/config.json:ro" \
    "${SS_IMAGE}"
test ! -e "${ROOT}/data/${WS_ID}.json" ||
  docker run --detach --name "${WS_ID}" --network "container:${NV_ID}" --cap-drop NET_RAW \
    --log-opt max-size=10m --log-opt max-file=3 \
    --volume "${WS_ID}:/data" \
    --volume "${ROOT}/data/${WS_ID}.json:/config/caddy/config.json:ro" \
    "${WS_IMAGE}" caddy run --config /config/caddy/config.json

############################
###   Internal scripts   ###
############################

# Create a task to watch the containers
cat >"${TASK_TO_WATCH}" <<EOL
#!/bin/sh
export PATH="${PATH}"
log() { echo "\$(date) - \${1}" >> "${LOG}"; }
state() { docker inspect --format "\${2}" "\${1}" 2>/dev/null; }
# Log changes of the health and restart NordVPN if it stays unhealthy for 10 minutes (its own recovery has hung)
health=\$(state ${NV_ID} '{{.State.Status}}/{{.State.Health.Status}}') || health="absent"
read -r previous streak 2>/dev/null <"${ROOT}/data/health" || previous="" streak=0
test "\${health}" = "\${previous}" && streak=\$((\${streak:-0} + 1)) || { streak=0; log "NordVPN is \${health}"; }
test "\${health}" != "running/unhealthy" || test \${streak} -lt 10 ||
  { log "Restart ${NV_ID} because it stays unhealthy"; docker restart ${NV_ID} >/dev/null 2>&1 || log "Cannot restart ${NV_ID}"; streak=0; }
echo "\${health} \${streak}" >"${ROOT}/data/health"
# Restart the channels if NordVPN has been restarted or they are stopped, as soon as the guard against leaks is up
vpn=\$(state ${NV_ID} '{{if .State.Running}}{{.State.StartedAt}}{{end}}') && test -n "\${vpn}" || exit 0
docker exec ${NV_ID} test -e /run/vpn.status >/dev/null 2>&1 || exit 0
test "\${vpn}" = "\$(cat "${ROOT}/data/started" 2>/dev/null)" && reason="" || reason="${NV_ID} has been restarted"
for id in ${SS_ID} ${WS_ID}; do
  running=\$(state "\${id}" '{{.State.Running}}') || continue
  test -z "\${reason}" && test "\${running}" = "true" && continue
  log "Restart \${id} because \${reason:-it is stopped}"
  docker restart "\${id}" >/dev/null 2>&1 || { log "Cannot restart \${id}"; vpn=""; }
done
# Stop the channels if NordVPN has been restarted meanwhile (they have joined a network without the guard)
test -z "\${vpn}" || { test "\${vpn}" = "\$(state ${NV_ID} '{{.State.StartedAt}}')" && docker exec ${NV_ID} test -e /run/vpn.status; } >/dev/null 2>&1 ||
  { log "Stop the channels because ${NV_ID} has been restarted meanwhile"; docker stop ${SS_ID} ${WS_ID} >/dev/null 2>&1; vpn=""; }
test -z "\${vpn}" || echo "\${vpn}" >"${ROOT}/data/started"
EOL
(
  crontab -l 2>/dev/null | grep --invert-match "${TITLE}" || :
  echo "* * * * * flock -n /run/${TITLE}.lock timeout 50s sh ${TASK_TO_WATCH} >/dev/null 2>&1"
) | crontab -

# Create a task to reinstall this tool
test "${BASH_EXECUTION_STRING:-}" && echo "${BASH_EXECUTION_STRING}" >"${TASK_TO_REINSTALL}" ||
  cp "${BASH_SOURCE[0]-}" "${TASK_TO_REINSTALL}" 2>/dev/null || :

# Create a task to uninstall this tool
cat >"${TASK_TO_UNINSTALL}" <<EOL
#!/bin/sh
export PATH="${PATH}"${REMOVE_REQUIREMENTS}
log() { echo "\$(date) - \${1}" >> "${LOG}"; }
log "Remove components";${REMOVE_INSTRUCTIONS}
  command_exists docker && docker image rm --force ${SS_IMAGE} ${WS_IMAGE} ${YQ_IMAGE} >/dev/null 2>&1
log "Remove all the files";
  crontab -l 2>/dev/null | grep --invert-match "${TITLE}" | crontab -
  rm --recursive --force "${ROOT}"
EOL

# Make all the tasks executable
chmod +x "${ROOT}/bin/"*

# Save and show the guide
clear -x && GUIDE="$(info "NordVPN Gateway")\n\n${GUIDE}"
echo -e "${GUIDE}" | sed 's/\x1B\[[0-9;]*[JKmsu]//g; s/\x1B(B//g' >"${ROOT}/guide.txt"
echo -e "${GUIDE}"
# Wait for the tunnel
info "\nWait for the tunnel...\n"
for i in $(seq 1 36); do
  test "$(docker inspect --format '{{.State.Health.Status}}' "${NV_ID}")" = "healthy" && break
  sleep 5
done
docker logs --tail 3 "${NV_ID}"
test "$(docker inspect --format '{{.State.Health.Status}}' "${NV_ID}")" = "healthy" ||
  error "The tunnel is not up yet, the containers keep trying, see 'docker logs ${NV_ID}'"
