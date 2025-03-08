#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

TITLE="vpn-gateway"
ROOT="/opt/${TITLE}"
TCP_PORTS=(22) # TCP only
ALL_PORTS=()   # TCP and UDP
TASK_TO_START="${ROOT}/bin/gateway.sh"
TASK_TO_REINSTALL="${ROOT}/bin/reinstall.sh"
TASK_TO_UNINSTALL="${ROOT}/bin/uninstall.sh"
declare GUIDE
declare PUBLIC
declare VPN_UP
declare VPN_REPAIR
declare REMOVE_REQUIREMENTS
declare REMOVE_INSTRUCTIONS
CIPHER="chacha20-ietf-poly1305"
SS_IMAGE="ghcr.io/shadowsocks/ssserver-rust:latest"
WS_IMAGE="ghcr.io/give-me/outlinecaddy:latest"
CF_IMAGE="cloudflare/cloudflared:latest"


#############################
###   Helping functions   ###
#############################

#---------------------
# Messages and dialogs
#---------------------

function style() {
  msg="$(tput setaf "${1}")${2}"
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
    read -r
    test -z "${REPLY}" || return 0
  done
}

function confirm() {
  while :; do
    ask "${1} [Y/N]"
    read -r -s -n 1
    [[ "${REPLY}" =~ ^y|Y$ ]] && echo "Y" && sleep 1 && return 0
    [[ "${REPLY}" =~ ^n|N$ ]] && echo "N" && sleep 1 && return 1
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
}

#----------------
# Other functions
#----------------

function command_exists {
  command -v "$@" &>/dev/null
}

function package_exists {
  dpkg -l | grep --quiet "$@"
}

function install_docker() {
  if ! command_exists docker; then
    info "Install Docker\n"
    curl -fsSL https://get.docker.com | sh
  fi
}

function generate_port() {
  echo $((1024 + RANDOM + (RANDOM % 2) * 30000))
}

function generate_rand() {
  local length=50
  openssl rand -base64 ${length} | tr -dc 'A-Za-z0-9' | head -c ${length}
}

################################
###   Setting up this tool   ###
################################

#--------------------
# Checks and analysis
#--------------------

# Check permissions
test $EUID -eq 0 || error "This tool should be executed by root only"
# Get details of a main interface
DEV=$(ip route show default | head -n 1 | awk '{print $5}')
GW=$(ip route show default | head -n 1 | awk '{print $3}')
IP=$(ip -oneline route get '1.1.1.1' oif "${DEV}" | awk '{print $7}')
CIDR=$(ip route show proto kernel | grep "${IP}" | awk '{print $1}')
# Extend the guide
GUIDE+="$(info "Interface ${DEV} was detected as default:")\n"
GUIDE+="$(info "- IP:" "${IP}")\n"
GUIDE+="$(info "- CIDR:" "${CIDR}")\n"
GUIDE+="$(info "- Gateway:" "${GW}")\n\n"

#------------------------
# Installing dependencies
#------------------------

if ! package_exists yq; then
  apt install yq -y
fi

#----------------------
# Preparing file system
#----------------------

mkdir --parents ${ROOT}/{bin,settings,data}

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

#---------------------------
# Most useful ports to allow
#---------------------------

clear -x
if confirm "Should ports for HTTP and HTTPS be allowed for other needs?"; then
  TCP_PORTS+=(80 443)
fi

##########################################
###   Channels to connect the server   ###
##########################################

REMOVE_REQUIREMENTS+="
$(declare -f command_exists)"

#----------------------------------------
# Shadowsocks (traffic masking available)
#----------------------------------------

id="shadowsocks-ss"
remove="
  # Shadowsocks
  command_exists docker && docker rm --force ${id} 2>/dev/null
  rm --force ${ROOT}/settings/${id}
  rm --force ${ROOT}/data/${id}.json"
REMOVE_INSTRUCTIONS+="${remove}"
clear -x
if confirm "Should this server be accessible via Shadowsocks?"; then
  install_docker && docker pull "${SS_IMAGE}"
  # Generate missing settings and load the settings
  if test ! -e "${ROOT}/settings/${id}"; then
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
      settings+="prefix='${REPLY}'\n" && prompt "Specify a port" && settings+="port=${REPLY}"
    else
      settings+="port=$(generate_port)"
    fi
    echo -e "${settings}" >"${ROOT}/settings/${id}"
  fi
  source "${ROOT}/settings/${id}"
  # Create a config
  config="server: 0.0.0.0\n"
  config+="server_port: ${port}\n"
  config+="password: ${secret}\n"
  config+="method: ${CIPHER}"
  echo -e "${config}" | yq >"${ROOT}/data/${id}.json"
  # Run a new container
  ALL_PORTS+=("${port}")
  docker rm --force "${id}" 2>/dev/null
  docker run --detach --name "${id}" --restart always --net host \
    --volume "${ROOT}/data/${id}.json:/etc/shadowsocks-rust/config.json" \
    "${SS_IMAGE}"
  # Extend the guide
  userinfo="${CIPHER}:${secret}"
  userinfo="$(echo -n "${userinfo}" | base64 --wrap=0)"
  url="ss://${userinfo}@${PUBLIC}:${port}"
  test -n "${prefix+x}" && url+="/?prefix=${prefix}"
  url+="#${TITLE}"
  GUIDE+="$(info "In order to access via Shadowsocks, do the following:")\n"
  GUIDE+="$(info "1) Ensure that the port is open:" "${port} (TCP and UDP)")\n"
  GUIDE+="$(info "2) Configure Outline Client with the following URL:" "${url}")\n\n"
else eval "${remove}"; fi

#----------------------------
# Shadowsocks-over-WebSockets
#----------------------------

id="shadowsocks-ws"
remove="
  # Shadowsocks-over-WebSockets
  command_exists docker && {
    docker rm --force ${id} 2>/dev/null
    docker volume rm --force ${id} 2>/dev/null
  }
  rm --force ${ROOT}/settings/${id}
  rm --force ${ROOT}/data/${id}.json"
REMOVE_INSTRUCTIONS+="${remove}"
clear -x
if ! [[ "${PUBLIC}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  && confirm "Should this server be accessible via Shadowsocks-over-WebSockets?"; then
  install_docker && docker pull "${WS_IMAGE}"
  # Generate missing settings and load the settings
  if test ! -e "${ROOT}/settings/${id}"; then
    settings="key_path='$(generate_rand)'\n"
    settings+="tcp_path='$(generate_rand)'\n"
    settings+="udp_path='$(generate_rand)'\n"
    settings+="secret='$(generate_rand)'"
    echo -e "${settings}" >"${ROOT}/settings/${id}"
  fi
  source "${ROOT}/settings/${id}"
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
  config="apps:\n"
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
  config+="    servers:\n"
  config+="      server:\n"
  config+="        listen: [':443']\n"
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
  # Add optional redirect for other paths
  if confirm "Would you like to specify an HTTP status code for bad paths?"; then
    choose "Choose an HTTP status code for bad paths" \
      301 "301 – Permanent Redirect" \
      302 "302 – Temporary Redirect" \
      401 "401 – Unauthorized" \
      403 "403 – Forbidden" \
      404 "404 – Not Found" \
      500 "500 – Server Error"
    # Add configuration to Caddy config
    config+="        - match:\n"
    config+="          - host: ['${PUBLIC}']\n"
    config+="          handle:\n"
    config+="          - handler: static_response\n"
    config+="            status_code: ${REPLY}\n"
    # If redirect code is selected, prompt for a URL
    if [ "${REPLY}" = 301 ] || [ "${REPLY}" = 302 ]; then
      prompt "Specify a URL to redirect to (e.g. https://example.com)"
      config+="            headers:\n"
      config+="              Location: [${REPLY}]\n"
    fi
  fi
  echo -e "${config}" | yq >"${ROOT}/data/${id}.json"
  # Run a new container
  ALL_PORTS+=(443)
  docker rm --force "${id}" 2>/dev/null
  docker run --detach --name "${id}" --restart always --net host \
    --volume "${id}:/data" \
    --volume "${ROOT}/data/${id}.json:/config/caddy/config.json" \
    "${WS_IMAGE}" caddy run --config /config/caddy/config.json
  # Extend the guide
  url="ssconf://${PUBLIC}/${key_path}#${TITLE}"
  GUIDE+="$(info "In order to access via Shadowsocks-over-WebSockets, do the following:")\n"
  GUIDE+="$(info "1) Ensure that the port is open:" "443 (TCP and UDP)")\n"
  GUIDE+="$(info "2) Configure Outline Client with the following URL:" "${url}")\n\n"
else eval "${remove}"; fi

#-----------------------------
# Shadowsocks with Outline VPN
#-----------------------------

remove="
  # Shadowsocks with Outline VPN
  command_exists docker && docker rm --force shadowbox watchtower 2>/dev/null
  rm --recursive --force /opt/outline
  rm --force ${ROOT}/settings/outline"
REMOVE_INSTRUCTIONS+="${remove}"
clear -x
if confirm "Should this server be accessible via Shadowsocks with Outline VPN?"; then
  install_docker
  # Generate missing numbers of public ports and load the numbers
  if test ! -e "${ROOT}/settings/outline"; then
    settings="api_port=$(generate_port)\n"
    settings+="keys_port=$(generate_port)"
    echo -e "${settings}" >"${ROOT}/settings/outline"
  fi
  source "${ROOT}/settings/outline"
  TCP_PORTS+=("${api_port}")
  ALL_PORTS+=("${keys_port}")
  # Install and run Outline VPN
  url="https://github.com/Jigsaw-Code/outline-server/raw/master"
  url+="/src/server_manager/install_scripts/install_server.sh"
  docker ps --all | grep shadowbox >/dev/null ||
    SB_DEFAULT_SERVER_NAME="${TITLE}" \
    bash -c "$(curl -fsSL ${url})" -- \
    --hostname="${PUBLIC}" \
    --api-port="${api_port}" \
    --keys-port="${keys_port}"
  # Extend the guide if Outline VPN has been configured
  secret="/opt/outline/access.txt"
  api_url=$(grep "apiUrl" "${secret}" | sed "s/apiUrl://" || :)
  cert_sha=$(grep "certSha256" "${secret}" | sed "s/certSha256://" || :)
  details="apiUrl: ${api_url}\n"
  details+="certSha256: ${cert_sha}"
  details=$(echo -e "${details}" | yq --indent 0)
  if test "${api_url}" -a "${cert_sha}"; then
    GUIDE+="$(info "In order to access via Outline VPN, do the following:")\n"
    GUIDE+="$(info "1) Ensure that ports are open:")\n"
    GUIDE+="$(info "- management port:" "${api_port} (TCP)")\n"
    GUIDE+="$(info "- access key port:" "${keys_port} (TCP and UDP)")\n"
    GUIDE+="$(info "2) Configure Outline Manager with the following string:" "${details}")\n\n"
  fi
else eval "${remove}"; fi

#----------------------
# Cloudflare Zero Trust
#----------------------

cloudflared_src="${ROOT}/data/cloudflared"
cloudflared_dst="/home/nonroot/.cloudflared/"
function cloudflared() {
  docker run --rm \
    --volume "${cloudflared_src}:${cloudflared_dst}" \
    "${CF_IMAGE}" "$@"
}
function cloudflared_service() {
  docker run --detach --name cloudflared --restart always \
    --volume "${cloudflared_src}:${cloudflared_dst}" \
    "${CF_IMAGE}" "$@"
}
remove="
  # Cloudflare Zero Trust
  command_exists docker && docker ps --all | grep cloudflared >/dev/null &&
    cloudflared tunnel list --name ${TITLE} 2>/dev/null | grep --quiet ${TITLE} && {
      cloudflared tunnel route ip delete 0.0.0.0/0
      cloudflared tunnel delete --force ${TITLE}
    }
  command_exists docker && docker rm --force cloudflared 2>/dev/null
  rm --recursive --force ${ROOT}/data/cloudflared"
REMOVE_INSTRUCTIONS+="${remove}"
REMOVE_REQUIREMENTS+="
cloudflared_src=${cloudflared_src}
cloudflared_dst=${cloudflared_dst}
$(declare -f cloudflared)"
clear -x
if confirm "Should this server be used as a gateway for Cloudflare Zero Trust?"; then
  install_docker && docker pull "${CF_IMAGE}"
  mkdir --parents --mode=777 "${cloudflared_src}"
  # Log in to Cloudflare
  cloudflared tunnel login
  # Find and check a tunnel
  if cloudflared tunnel list --name "${TITLE}" | grep --quiet "${TITLE}"; then
    info "Found the tunnel \"${TITLE}\" at Cloudflare Zero Trust\n"
    tunnel=$(cloudflared tunnel list --name "${TITLE}" --output yaml)
    tunnel=$(echo -e "${tunnel}" | yq '.[0].id' | tr -d '"')
    info "Its ID is \"${tunnel}\"\n"
    if test ! -e "${ROOT}/data/cloudflared/${tunnel}.json"; then
      info "Delete the tunnel because its certificate missed\n"
      cloudflared tunnel route ip delete 0.0.0.0/0
      cloudflared tunnel delete --force "${TITLE}"
    fi
  fi
  # Create a tunnel if absent
  if ! cloudflared tunnel list --name "${TITLE}" | grep --quiet "${TITLE}"; then
    info "Create a new tunnel to have a certificate\n"
    cloudflared tunnel create "${TITLE}"
  fi
  # Add routing if absent
  if ! cloudflared tunnel route ip show | grep 0.0.0.0/0 | grep --quiet "${TITLE}"; then
    info "Add routing to the tunnel for all the traffic\n"
    cloudflared tunnel route ip add 0.0.0.0/0 "${TITLE}"
  fi
  # Create a config
  config="tunnel: ${TITLE}\n"
  config+="warp-routing:\n  enabled: true"
  echo -e "${config}" >"${ROOT}/data/cloudflared/config.yml"
  # Run a new container
  docker rm --force cloudflared 2>/dev/null
  cloudflared_service tunnel run
  # Extend the guide
  GUIDE+="$(info "In order to access via Cloudflare Zero Trust, do the following:")\n"
  GUIDE+="$(info "1) Download Cloudflare One")\n"
  GUIDE+="$(info "2) Log users in to your Zero Trust organization")\n\n"
else eval "${remove}"; fi

###################################
###   VPN preventing IP leaks   ###
###################################

remove="
  # NordVPN
  command_exists nordvpn && {
    nordvpn disconnect
    nordvpn logout
    apt remove nordvpn -y
  }"
REMOVE_INSTRUCTIONS+="${remove}"
# Install NordVPN
if ! command_exists nordvpn; then
  curl -fsSL https://downloads.nordcdn.com/apps/linux/install.sh | sh
fi
# Install an unmentioned dependency
if ! package_exists wireguard-tools; then
  apt install wireguard-tools -y
fi
# Log in to NordVPN
clear -x
while ! nordvpn account >/dev/null; do
  info "Please, do the following:\n"
  info "1) Log you in at https://my.nordaccount.com/dashboard/nordvpn/access-tokens/\n"
  info "2) Generate new token and past the token below (non-expirable token is better)\n"
  prompt "Specify the token" && nordvpn login --token "${REPLY}" || :
done
# Let choose a country or group as prior
vpn="nordvpn connect"
clear -x
if confirm "Would you like to force NordVPN to choose a specific country?"; then
  info "Available countries:\n" && nordvpn countries
  info "Available groups:\n" && nordvpn groups
  prompt "Specify a country or group" && prior="${REPLY}"
  vpn="${vpn} ${prior} || ${vpn}"
fi
# Set instructions:
# - to start vpn
VPN_UP="
log \"Configure VPN\"
nordvpn whitelist remove all
$(for port in ${TCP_PORTS[*]} ${ALL_PORTS[*]}; do
  echo "nordvpn whitelist add port ${port}"
done)
nordvpn whitelist add subnet ${CIDR}
nordvpn set autoconnect on
nordvpn set killswitch on
nordvpn set dns 1.1.1.1 8.8.8.8
nordvpn set technology NordLynx
log \"Connect VPN\"
${vpn} || {
  nordvpn account >/dev/null &&
  log \"Something goes wrong. Try to run 'nordvpn connect'\" ||
  log \"Seems like you logged out. Try to run '${TASK_TO_REINSTALL}'\"
  log \"This tool stopped until reboot the server\"; exit 1
}"
# - to repair vpn
VPN_REPAIR="
  log \"Connection lost. Try to reconnect NordVPN\"
    timeout 10s bash -c \"${vpn}\" &&
    log \"NordVPN has successfully reconnected\" &&
    continue
  log \"Try to restart NordVPN's services\"
    timeout 30s systemctl restart nordvpn.service &&
    timeout 30s systemctl restart nordvpnd.service &&
    log \"The services have successfully restarted\" &&
    continue"

# Extend the guide
GUIDE+="$(info "NordVPN has been successfully configured:")\n"
GUIDE+="$(info "- prior country or group:" "${prior:-none}")\n"
GUIDE+="$(info "- allowed TCP only ports:" "${TCP_PORTS[*]}")\n"
GUIDE+="$(info "- allowed TCP and UDP ports:" "${ALL_PORTS[*]}")\n\n"
GUIDE+="$(info "Now reboot the server to up the gateway")\n"

############################
###   Internal scripts   ###
############################

# Create a task to start the gateway
cat >"${TASK_TO_START}" <<EOL
#!/bin/sh
export PATH=${PATH}
log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
check() { ping -q -w 3 1.1.1.1 || ping -q -w 3 8.8.8.8 || return 1; }
log "Wait some time and boot up"; sleep 10;
# Enable BBR to improve network performance
sysctl net.core.default_qdisc=fq
sysctl net.ipv4.tcp_congestion_control=bbr
# Increase the maximum buffer sizes
sysctl -w net.core.rmem_max=7500000
sysctl -w net.core.wmem_max=7500000
# Start VPN ${VPN_UP}
# Configure routing
ip rule add from ${IP} table 123
ip route add table 123 to ${CIDR} dev ${DEV}
ip route add table 123 default via ${GW}
# Check health
while :
do
  # Check the connection twice
  sleep 10; check || check && continue
  # Try to repair VPN ${VPN_REPAIR}
  log "Reboot the server"; reboot --force --force
done
EOL
(
  crontab -l 2>/dev/null | grep --invert-match "${TITLE}" || :
  echo "@reboot sh ${TASK_TO_START} >/dev/null 2>&1"
) | crontab -

# Create a task to reinstall this tool
test "${BASH_EXECUTION_STRING:-}" &&
  echo "${BASH_EXECUTION_STRING}" >"${TASK_TO_REINSTALL}"

# Create a task to uninstall this tool
cat >"${TASK_TO_UNINSTALL}" <<EOL
#!/bin/sh
export PATH=${PATH}${REMOVE_REQUIREMENTS}
log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
log "Remove components";${REMOVE_INSTRUCTIONS}
  command_exists docker && docker system prune --force --all 2>/dev/null
log "Restore routing";
  ip rule del table 123 2>/dev/null
  ip route flush table 123 2>/dev/null
log "Remove all the files";
  crontab -l | grep --invert-match "${TITLE}" | crontab -
  rm --recursive --force "${ROOT}"
EOL

# Make all the tasks executable
chmod +x "${ROOT}/bin/"*

# Save the guide and notify about following actions
clear -x && GUIDE="$(info "NordVPN Gateway " "v. 0.11")\n\n${GUIDE}"
echo -e ${GUIDE} | sed 's/\x1B\[[0-9;]*[JKmsu]//g' >"${ROOT}/guide.txt"
echo -e ${GUIDE}
