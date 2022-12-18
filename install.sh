#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

TITLE="vpn-gateway"
ROOT="/opt/${TITLE}"
TCP_PORTS=(22) # TCP only
ALL_PORTS=()   # TCP and UDP
declare GUIDE
declare VPN_UP
declare VPN_REPAIR
declare REMOVE_REQUIREMENTS
declare REMOVE_ALL

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
    [[ "${REPLY}" =~ ^y|Y$ ]] && echo && return 0
    [[ "${REPLY}" =~ ^n|N$ ]] && echo && return 1
    style 1 "${REPLY} is a wrong answer\n"
  done
}

#---------------------
#   Other functions  |
#---------------------

function command_exists {
  command -v "$@" &>/dev/null
}

function package_exists {
  dpkg -l | grep --quiet "$@"
}

function install_docker() {
  if ! command_exists docker; then
    curl -sSL https://get.docker.com/ | sh
  fi
}

function generate_port() {
  echo $((1024 + RANDOM + (RANDOM % 2) * 30000))
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
DEV=$(ip route show default | awk '{print $5}')
GW=$(ip route show default | awk '{print $3}')
IP=$(ip -oneline route get '1.1.1.1' oif "${DEV}" | awk '{print $7}')
CIDR=$(ip route show proto kernel | grep "${IP}" | awk '{print $1}')
# Extend the guide
GUIDE+="$(info "Interface ${DEV} was detected as default:")\n"
GUIDE+="$(info "- IP:" "${IP}")\n"
GUIDE+="$(info "- CIDR:" "${CIDR}")\n"
GUIDE+="$(info "- Gateway:" "${GW}")\n\n"

#----------------------
# Preparing file system
#----------------------

mkdir --parents ${ROOT}/{bin,settings,configs}

############################
###   General settings   ###
############################

#---------------------------
# Public IP or a domain name
#---------------------------

clear -x
info "The following IP was found for the interface ${DEV}:" "${IP}\n"
if confirm "Should a domain or another IP be used to access this server?"; then
  prompt "Specify a domain or IP instead of ${IP}"
  PUBLIC="${REPLY}"
else PUBLIC="${IP}"; fi

#---------------------------
# Most useful ports to allow
#---------------------------

clear -x
if confirm "Should ports for HTTP and HTTPS be allowed?"; then
  TCP_PORTS+=(80 443)
fi

##########################################
###   Channels to connect the server   ###
##########################################

#-----------------------
# Standalone Shadowsocks
#-----------------------

remove="
  # Shadowsocks
  command -v docker &>/dev/null && docker rm --force shadowsocks 2>/dev/null
  rm --force ${ROOT}/settings/shadowsocks
  rm --force ${ROOT}/configs/shadowsocks.json"
REMOVE_ALL+="${remove}"
clear -x
if confirm "Should this server be accessible via Shadowsocks?"; then
  install_docker
  # Generate missing settings and load the settings
  if [ ! -f "${ROOT}/settings/shadowsocks" ]; then
    settings="shadowsocks_secret='$(head -c 10 /dev/urandom | base64)'\n"
    settings+="shadowsocks_port=$(generate_port)"
    echo -e "${settings}" >"${ROOT}/settings/shadowsocks"
  fi
  source "${ROOT}/settings/shadowsocks"
  ALL_PORTS+=("${shadowsocks_port}")
  # Create a config
  shadowsocks_method="chacha20-ietf-poly1305"
  config="{ 'server': '0.0.0.0', 'server_port': ${shadowsocks_port},"
  config+=" 'password': '${shadowsocks_secret}', 'method': '${shadowsocks_method}' }"
  echo -e "${config}" >"${ROOT}/configs/shadowsocks.json"
  # Stop and run a server
  docker rm --force shadowsocks 2>/dev/null
  docker run --detach --restart always --net host --name shadowsocks \
    --volume "${ROOT}/configs/shadowsocks.json:/etc/shadowsocks-rust/config.json" \
    ghcr.io/shadowsocks/ssserver-rust:latest
  # Extend the guide
  details="${shadowsocks_method}:${shadowsocks_secret}@${PUBLIC}:${shadowsocks_port}"
  shadowsocks_url="ss://$(echo -n "${details}" | base64 --wrap=0)#${TITLE}"
  GUIDE+="$(info "In order to access via Shadowsocks, do the following:")\n"
  GUIDE+="$(info "1) Ensure that the port is open:" "${shadowsocks_port} (TCP and UDP)")\n"
  GUIDE+="$(info "2) Configure Outline Client with the following URL:" "${shadowsocks_url}")\n\n"
else eval "${remove}"; fi

#------------
# Outline VPN
#------------

remove="
  # Outline VPN
  command -v docker &>/dev/null && docker rm --force shadowbox watchtower 2>/dev/null
  rm --recursive --force /opt/outline
  rm --force ${ROOT}/settings/outline"
REMOVE_ALL+="${remove}"
clear -x
if confirm "Should this server be accessible via Outline VPN?"; then
  install_docker
  # Generate missing numbers of public ports and load the numbers
  if [ ! -f "${ROOT}/settings/outline" ]; then
    settings="outline_api_port=$(generate_port)\n"
    settings+="outline_keys_port=$(generate_port)"
    echo -e "${settings}" >"${ROOT}/settings/outline"
  fi
  source "${ROOT}/settings/outline"
  TCP_PORTS+=("${outline_api_port}")
  ALL_PORTS+=("${outline_keys_port}")
  # Install and run Outline VPN
  url="https://github.com/Jigsaw-Code/outline-server/raw/master"
  url+="/src/server_manager/install_scripts/install_server.sh"
  docker ps --all | grep shadowbox >/dev/null || bash -c "$(curl -sSL ${url})" -- \
    --hostname="${PUBLIC}" \
    --api-port="${outline_api_port}" \
    --keys-port="${outline_keys_port}"
  # Extend the guide if Outline VPN has been configured
  secret="/opt/outline/access.txt"
  api_url=$(grep "apiUrl" "${secret}" | sed "s/apiUrl://" || echo)
  cert_sha=$(grep "certSha256" "${secret}" | sed "s/certSha256://" || echo)
  details="{\"apiUrl\":\"${api_url}\",\"certSha256\":\"${cert_sha}\"}"
  if [ "${api_url}" ] && [ "${cert_sha}" ]; then
    GUIDE+="$(info "In order to access via Outline VPN, do the following:")\n"
    GUIDE+="$(info "1) Ensure that ports are open:")\n"
    GUIDE+="$(info "- management port:" "${outline_api_port} (TCP)")\n"
    GUIDE+="$(info "- access key port:" "${outline_keys_port} (TCP and UDP)")\n"
    GUIDE+="$(info "2) Configure Outline Manager with the following string:" "${details}")\n\n"
  fi
else eval "${remove}"; fi

#---------------------
# Cloudflare for Teams
#---------------------

src="${ROOT}/configs/cloudflared"
dst="/home/nonroot/.cloudflared/"
function cloudflared() {
  docker run --rm \
    --volume "${src}:${dst}" cloudflare/cloudflared:latest "$@"
}
function cloudflared_service() {
  docker run --detach --name cloudflared --restart always \
    --volume "${src}:${dst}" cloudflare/cloudflared:latest "$@"
}
remove="
  # Cloudflare for Teams
  command -v docker &>/dev/null && docker ps --all | grep cloudflared >/dev/null &&
    cloudflared tunnel list --name ${TITLE} 2>/dev/null | grep --quiet ${TITLE} && {
      cloudflared tunnel route ip delete 0.0.0.0/0
      cloudflared tunnel delete --force ${TITLE}
    }
  command -v docker &>/dev/null && docker rm --force cloudflared 2>/dev/null
  rm --recursive --force ${ROOT}/configs/cloudflared"
REMOVE_REQUIREMENTS+="
src=${src}
dst=${dst}
$(declare -f cloudflared)"
REMOVE_ALL+="${remove}"
clear -x
if confirm "Should this server be used as a gateway for Cloudflare for Teams?"; then
  install_docker
  # Log in to Cloudflare
  cloudflared tunnel login
  # Find and check a tunnel
  if cloudflared tunnel list --name "${TITLE}" | grep --quiet "${TITLE}"; then
    info "Found the tunnel \"${TITLE}\" at Cloudflare for Teams\n"
    tunnel=$(cloudflared tunnel list --name "${TITLE}" --output yaml)
    tunnel=$(echo -e "${tunnel}" | head -n 1 | awk '{print $3}')
    info "Its ID is \"${tunnel}\"\n"
    if [ ! -f "${ROOT}/configs/cloudflared/${tunnel}.json" ]; then
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
  echo -e "${config}" >"${ROOT}/configs/cloudflared/config.yml"
  # Run a new container
  docker rm --force cloudflared 2>/dev/null
  cloudflared_service tunnel run --force
  # Extend the guide
  GUIDE+="$(info "In order to access via Cloudflare for Teams, do the following:")\n"
  GUIDE+="$(info "1) Download Cloudflare WARP client")\n"
  GUIDE+="$(info "2) Log users in to your Team")\n\n"
else eval "${remove}"; fi

###################################
###   VPN preventing IP leaks   ###
###################################

remove="
  # NordVPN
  command -v nordvpn &>/dev/null && {
    nordvpn disconnect
    nordvpn logout
    apt remove nordvpn -y
  }"
REMOVE_ALL+="${remove}"
# Install NordVPN
if ! command_exists nordvpn; then
  curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh | sh
fi
# Install an unmentioned dependency
if ! package_exists wireguard-tools; then
  apt install wireguard-tools -y
fi
# Log in to NordVPN
clear -x
while ! nordvpn account >/dev/null; do
  info "Please, do the following:\n"
  info "1) Log you in at https://my.nordaccount.com/dashboard/nordvpn/\n"
  info "2) Find a section named \"Access token\"\n"
  info "3) Generate new token and past the token below\n"
  prompt "Specify the resulting url" && nordvpn login --token "${REPLY}" || echo
done
# Let choose a country or group as prior
vpn="nordvpn connect"
clear -x
if confirm "Do you like to force NordVPN to choose a specific country?"; then
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
nordvpn set dns 1.1.1.1
nordvpn set technology NordLynx
log \"Connect VPN\"
${vpn} || exit 1"
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
GUIDE+="$(info "Now restart the server to up the gateway")\n"

############################
###   Internal scripts   ###
############################

# Create a task on startup
cat >"${ROOT}/bin/up-vpn.sh" <<EOL
#!/bin/sh
export PATH=${PATH}
log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
check() { ping -q -w 5 1.1.1.1 || return 1; }
log "Wait some time and boot up"; sleep 10;
# Enable BBR to improve network performance
sysctl net.core.default_qdisc=fq
sysctl net.ipv4.tcp_congestion_control=bbr
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
  log "Reboot the server"; reboot --force
done
EOL
chmod +x "${ROOT}/bin/up-vpn.sh"
(
  crontab -l | grep --invert-match "${TITLE}"
  echo "@reboot sh ${ROOT}/bin/up-vpn.sh >/dev/null 2>&1"
) | crontab -

# Create a task to remove this tool
cat >"${ROOT}/bin/remove.sh" <<EOL
#!/bin/sh
export PATH=${PATH}${REMOVE_REQUIREMENTS}
log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
log "Remove requirements";${REMOVE_ALL}
  docker system prune --force --all
log "Restore routing";
  ip rule del table 123
  ip route flush table 123
log "Remove this tool";
  crontab -l | grep --invert-match "${TITLE}" | crontab -
  rm --recursive --force "${ROOT}"
EOL
chmod +x "${ROOT}/bin/remove.sh"

# Notify about following actions
clear -x && info "NordVPN Gateway\n\n" && echo -e ${GUIDE}
