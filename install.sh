#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

TITLE="vpn-gateway"
ROOT="/opt/${TITLE}"
PORTS=(22)
declare GUIDE
declare VPN_UP
declare VPN_READY
declare VPN_REPAIR
declare REMOVE_ALL

# Color messages and dialogs
style() {
  msg="$(tput setaf "${1}")${2}"
  test -z "${3-}" || msg+=" $(tput bold)${3}"
  echo -e -n "${msg}$(tput sgr0)"
}
function ask() { style 3 "${1} "; }
function info() { style 2 "${1}" "${2-}"; }
function error() { style 1 "${1}" "${2-}" && exit 1; }
function prompt() { while :; do
  ask "${1} [and press Enter]:" && read -r
  test -z "${REPLY}" || return 0
done; }
function confirm() { while :; do
  ask "${1} [Y/N]" && read -r -s -n 1
  [[ "${REPLY}" =~ ^y|Y$ ]] && echo && return 0
  [[ "${REPLY}" =~ ^n|N$ ]] && echo && return 1
  style 31 "wrong answer" && echo
done; }

# Check root permissions
test $EUID -ne 0 && error "You are not root"

# Make a root directory
mkdir --parents "${ROOT}/bin"

# Get details of a main interface
DEV=$(ip route show default | awk '{print $5}')
GW=$(ip route show default | awk '{print $3}')
IP=$(ip route get "${GW}" | awk '{print $5}')
CIDR=$(ip route | grep / | grep "${IP}" | awk '{print $1}')

# Extend the guide
GUIDE+="$(info "Interface ${DEV} was detected as default:")\n"
GUIDE+="$(info "- ip:" "${IP}")\n"
GUIDE+="$(info "- gateway:" "${GW}")\n"
GUIDE+="$(info "- CIDR:" "${CIDR}")\n\n"

# Additional parameters
clear -x && confirm "Would you like to open HTTP and HTTPS ports?" && PORTS+=(80 443)

##########################################
###   Channels to connect the server   ###
##########################################

# Make and append instructions to remove
clear -x && remove="
  # Outline VPN
  which docker >/dev/null && {
    docker rm --force shadowbox watchtower 2>/dev/null
    docker system prune --force --all
  }
  rm --recursive --force /opt/outline
  rm --force ${ROOT}/outline" && REMOVE_ALL+="${remove}"
if confirm "Should this server be accessible via Outline VPN?"; then
  # Install Docker
  which docker >/dev/null || curl -sSL https://get.docker.com/ | sh
  # Get or generate random numbers of public ports for Outline VPN
  test -f "${ROOT}/outline" || {
    ports="api_port=$((1024 + RANDOM + (RANDOM % 2) * 30000))\n"
    ports+="keys_port=$((1024 + RANDOM + (RANDOM % 2) * 30000))"
    echo -e "${ports}" >"${ROOT}/outline"
  } && source "${ROOT}/outline" && PORTS+=("${api_port}" "${keys_port}")
  # Get a custom host if it is a new installation
  hostname="$IP" && config="/opt/outline/access.txt"
  test -f ${config} || {
    info "Ensure that ports ${api_port} (TCP) and ${keys_port} (TCP and UDP) are open\n"
    confirm "Would you like to access Outline VPN by IP ${IP}?" ||
      { prompt "Specify another IP or a domain name" && hostname="${REPLY}"; }
  }
  # Install and run Outline VPN
  url="https://github.com/Jigsaw-Code/outline-server/raw/master"
  url+="/src/server_manager/install_scripts/install_server.sh"
  docker ps | grep shadowbox >/dev/null || bash -c "$(curl -sSL ${url})" -- \
    --hostname="${hostname}" --api-port="${api_port}" --keys-port="${keys_port}"
  # Extend the guide
  api_url=$(grep "apiUrl" "${config}" | sed "s/apiUrl://")
  cert_sha=$(grep "certSha256" "${config}" | sed "s/certSha256://")
  secret="{\"apiUrl\":\"${api_url}\",\"certSha256\":\"${cert_sha}\"}"
  GUIDE+="$(info "In order to access via Outline VPN, do the following:")\n"
  GUIDE+="$(info "1) Ensure that ports are open:")\n"
  GUIDE+="$(info "- management port:" "${api_port} (TCP)")\n"
  GUIDE+="$(info "- access key port:" "${keys_port} (TCP and UDP)")\n"
  GUIDE+="$(info "2) Configure Outline Manager with the following string:" "${secret}")\n\n"
else eval "${remove}"; fi

# Make and append instructions to remove
clear -x && remove="
  # Cloudflare for Teams
  which cloudflared >/dev/null && {
    cloudflared tunnel list --name ${TITLE} 2>/dev/null | grep ${TITLE} >/dev/null && {
      cloudflared tunnel route ip delete 0.0.0.0/0
      cloudflared tunnel delete --force ${TITLE}
    }; apt remove cloudflared -y
  }
  rm --force ${ROOT}/cloudflared.yml" && REMOVE_ALL+="${remove}"
if confirm "Should this server be used as a gateway for Cloudflare for Teams?"; then
  # Install Cloudflare client
  which cloudflared >/dev/null || {
    arch=$(dpkg --print-architecture) && deb="$(mktemp)"
    url="https://github.com/cloudflare/cloudflared/releases"
    url+="/latest/download/cloudflared-linux-${arch}.deb"
    wget --quiet --output-document="${deb}" "${url}" && dpkg -i "${deb}"
  } || error "A package \"cloudflared\" cannot be installed"
  # Log in to Cloudflare
  cloudflared tunnel login
  # Delete a tunnel if its certificate missed
  cloudflared tunnel list --name "${TITLE}" | grep "${TITLE}" >/dev/null && {
    info "Found the tunnel \"${TITLE}\" at Cloudflare for Teams\n"
    tunnel=$(cloudflared tunnel list --name "${TITLE}" --output yaml)
    tunnel=$(echo -e "${tunnel}" | head -n 1 | awk '{print $3}')
    info "Its ID is \"${tunnel}\"\n"
    test -e "/root/.cloudflared/${tunnel}.json" || {
      info "Delete the tunnel because its certificate missed\n"
      cloudflared tunnel route ip delete 0.0.0.0/0
      cloudflared tunnel delete --force ${TITLE}
    }
  }
  # Create a tunnel if absent
  cloudflared tunnel list --name "${TITLE}" | grep "${TITLE}" >/dev/null || {
    info "Create a new tunnel to have a certificate\n"
    cloudflared tunnel create "${TITLE}"
  }
  # Add routing if absent
  cloudflared tunnel route ip show | grep 0.0.0.0/0 | grep "${TITLE}" >/dev/null || {
    info "Add routing to the tunnel for all the traffic\n"
    cloudflared tunnel route ip add 0.0.0.0/0 "${TITLE}"
  }
  # Create a config
  config="tunnel: ${TITLE}\n"
  config+="warp-routing:\n  enabled: true"
  echo -e "${config}" >"${ROOT}/cloudflared.yml"
  # Set instructions
  VPN_READY+="; cloudflared tunnel --config ${ROOT}/cloudflared.yml run --force &"
  # Extend the guide
  GUIDE+="$(info "In order to access via Cloudflare for Teams, do the following:")\n"
  GUIDE+="$(info "1) Download Cloudflare WARP client")\n"
  GUIDE+="$(info "2) Log users in to your Team")\n\n"
else eval "${remove}"; fi

###################################
###   VPN preventing IP leaks   ###
###################################

# Make and append instructions to remove
clear -x && remove="
  # NordVPN
  which nordvpn >/dev/null && {
    nordvpn disconnect
    nordvpn logout
    apt remove nordvpn -y
  }" && REMOVE_ALL+="${remove}"

# Install NordVPN
which nordvpn >/dev/null || curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Let choose a country or group as prior
clear -x && vpn="nordvpn connect"
confirm "Do you allow NordVPN to choose a server's country or group?" || {
  info "Available countries:\n" && nordvpn countries
  info "Available groups:\n" && nordvpn groups
  prompt "Specify a country or group" && prior="${REPLY}"
  vpn="${vpn} ${prior} || ${vpn}"
}

# Log in to NordVPN
while ! nordvpn account >/dev/null; do
  nordvpn login --nordaccount
  info "Please, do the following:\n"
  info "1) Log you in a browser by the url specified above\n"
  info "2) Copy a resulting url of the link named \"Return to the app\"\n"
  info "3) Past the resulting url below (it's similar to \"nordvpn://...\")\n"
  prompt "Specify the resulting url" && nordvpn login --callback "${REPLY}" || echo
done

# Set instructions:
# - to start vpn
VPN_UP="
log \"Configure VPN\"
nordvpn whitelist remove all
$(for port in ${PORTS[*]}; do
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
GUIDE+="$(info "- open ports:" "${PORTS[*]}")\n\n"
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
# Start VPN ${VPN_UP}${VPN_READY:-}
# Configure routing
ip rule add from ${IP} table 128
ip route add table 128 to ${CIDR} dev ${DEV}
ip route add table 128 default via ${GW}
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
echo "@reboot sh ${ROOT}/bin/up-vpn.sh >/dev/null 2>&1" | crontab -

# Create a task to remove this tool
cat >"${ROOT}/bin/remove.sh" <<EOL
#!/bin/sh
export PATH=${PATH}
log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
log "Remove requirements";${REMOVE_ALL}
log "Restore routing";
  ip rule del table 128
  ip route flush table 128
log "Remove this tool";
  crontab -l | grep --invert-match "${TITLE}" | crontab -
  rm --recursive --force "${ROOT}"
EOL
chmod +x "${ROOT}/bin/remove.sh"

# TODO: Remove this block after fixing the bug of NordVPN 3.11.0–3.12.0
#  (https://nordvpn.com/ru/blog/nordvpn-linux-release-notes/)
# Create a temporary task to fix freezing of NordVPN
# (approximately, each 2 hours 10 minutes). Details,
# reasons and solutions can be found here:
# - https://forum.manjaro.org/t/nordvpn-bin-breaks-every-4-hours/80927
# - https://aur.archlinux.org/packages/nordvpn-bin#comment-829416
# Commands to remove the temporary task:
#   rm /opt/vpn-behind-outline/bin/fix-vpn.sh
#   echo "@reboot sh /opt/vpn-behind-outline/bin/up-vpn.sh >/dev/null 2>&1" | crontab -
#
###################
###   Old way   ###
###################
#cat >"${ROOT}/bin/fix-vpn.sh" <<EOL
##!/bin/sh
#export PATH=${PATH}
#log() { echo "\$(date) - \${1}" >> "/var/log/${TITLE}.log"; }
#log "Re-create connection"; ${vpn}
#EOL
#chmod +x "${ROOT}/bin/fix-vpn.sh"
#crontab -l | {
#  cat
#  echo "0 */2 * * * sh ${ROOT}/bin/fix-vpn.sh >/dev/null 2>&1"
#} | crontab -
#
###################
###   New way   ###
###################
apt install wireguard-tools -y

# Notify about following actions
clear -x && info "NordVPN Gateway\n\n" && echo -e ${GUIDE}
