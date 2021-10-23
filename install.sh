#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

info() { echo -e "\033[32m${1} \033[1;32m${2-}\033[0m"; }

# Make a root directory
ROOT="/opt/vpn-behind-outline"
mkdir --parents "${ROOT}/bin"

# Get or make numbers of public ports for Outline
test -f "${ROOT}/ports" || cat >"${ROOT}/ports" <<EOL
API_PORT=$((1024 + RANDOM + (RANDOM % 2) * 30000))
KEYS_PORT=$((1024 + RANDOM + (RANDOM % 2) * 30000))
EOL
source "${ROOT}/ports"

# Calculate interface details
DEV=$(ip route show default | awk '{print $5}')
GW=$(ip route show default | awk '{print $3}')
IP=$(ip route get "${GW}" | awk '{print $5}')
CIDR=$(ip route | grep / | grep "${IP}" | awk '{print $1}')

# Install Docker
which docker >/dev/null ||
  curl -sSL https://get.docker.com/ | sh

# Install NordVPN
which nordvpn >/dev/null ||
  curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Install and run Outline
PUBLIC=$(test $# -eq 1 && echo "$@" || echo "$IP")
docker ps | grep shadowbox >/dev/null ||
  bash -c "$(curl -sSL https://github.com/Jigsaw-Code/outline-server/raw/master/src/server_manager/install_scripts/install_server.sh)" \
    install_server.sh \
    --hostname="${PUBLIC}" \
    --api-port="${API_PORT}" \
    --keys-port="${KEYS_PORT}"

# Create a task on startup
cat >"${ROOT}/bin/up-vpn.sh" <<EOL
#!/bin/sh
export PATH=$PATH
log() { echo "\$(date) - \${1}" >> /var/log/vpn.log; }
log "Wait some time and boot up"; sleep 10;
# Enable BBR to improve network performance
sysctl net.core.default_qdisc=fq
sysctl net.ipv4.tcp_congestion_control=bbr
# Configure NordVPN
nordvpn whitelist remove all
nordvpn whitelist add port 22
nordvpn whitelist add port ${API_PORT}
nordvpn whitelist add port ${KEYS_PORT}
nordvpn whitelist add subnet ${CIDR}
nordvpn set autoconnect on
nordvpn set killswitch on
nordvpn set dns 1.1.1.1
nordvpn set technology NordLynx
log "Run NordVPN"; nordvpn connect || exit 1
# Configure routing
ip rule add from ${IP} table 128
ip route add table 128 to ${CIDR} dev ${DEV}
ip route add table 128 default via ${GW}
# Check health
while :
do
  sleep 10; ping -q -w 5 1.1.1.1 && continue
  log "Lost connection"
  log "Try to reconnect NordVPN";
    timeout 10s nordvpn connect &&
    log "NordVPN has successfully reconnected" &&
    continue
  log "Try to restart NordVPN's services";
    timeout 30s systemctl restart nordvpn.service &&
    timeout 30s systemctl restart nordvpnd.service &&
    log "The services have successfully restarted" &&
    continue
  log "Reboot the server"; reboot --force
done
EOL
chmod +x "${ROOT}/bin/up-vpn.sh"
echo "@reboot sh ${ROOT}/bin/up-vpn.sh >/dev/null 2>&1" | crontab -

# TODO: Remove after fixing the bug of NordVPN 3.11.0
# Create a temporary task to fix freezing of NordVPN
# (approximately, each 4 hours 20 minutes). Details,
# reasons and solutions can be found here:
# - https://forum.manjaro.org/t/nordvpn-bin-breaks-every-4-hours/80927
# - https://aur.archlinux.org/packages/nordvpn-bin#comment-829416
# Commands to uninstall the temporary task:
#   rm /opt/vpn-behind-outline/bin/fix-vpn.sh
#   echo "@reboot sh /opt/vpn-behind-outline/bin/up-vpn.sh >/dev/null 2>&1" | crontab -
cat >"${ROOT}/bin/fix-vpn.sh" <<EOL
#!/bin/sh
log() { echo "\$(date) - \${1}" >> /var/log/vpn.log; }
log "Recreate connection"; nordvpn connect
EOL
chmod +x "${ROOT}/bin/fix-vpn.sh"
crontab -l | {
  cat
  echo "0 */4 * * * sh ${ROOT}/bin/fix-vpn.sh >/dev/null 2>&1"
} | crontab -

# Notify about following actions
clear -x
info "\nInterface ${DEV} was detected as default:"
info "- ip:" "${IP}"
info "- gateway:" "${GW}"
info "- CIDR:" "${CIDR}"
info "\nNordVPN behind Outline has been successfully configured:"
info "- management port:" "${API_PORT} (TCP)"
info "- access key port:" "${KEYS_PORT} (TCP and UDP)"
info "\nPlease, do the following:"
api=$(grep "apiUrl" "/opt/outline/access.txt" | sed "s/apiUrl://")
cert=$(grep "certSha256" "/opt/outline/access.txt" | sed "s/certSha256://")
secret="{\"apiUrl\":\"${api}\",\"certSha256\":\"${cert}\"}"
info "1) Configure Outline Manager with the following string:" "${secret}"
info "2) Run a command to log you in NordVPN:" "nordvpn login"
info "3) Run a command to restart the server:" "reboot"
