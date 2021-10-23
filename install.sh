#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

info() { echo -e "\033[1;32m${1}\033[0m"; }

# Calculate interface details
IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
CIDR=$(ip route | grep / | grep "${IP}" | awk '{print $1}')
GATEWAY=$(ip route show 0.0.0.0/0 | awk '{print $3}')
DEV=$(ip route show 0.0.0.0/0 | awk '{print $5}')
info "IP: ${IP}, CIDR: ${CIDR}, GATEWAY: ${GATEWAY}, DEV: ${DEV}"

# Install Docker
which docker >/dev/null ||
  curl -sSL https://get.docker.com/ | sh

# Install NordVPN
which nordvpn >/dev/null ||
  curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Install and run Outline
PUBLIC=$(test $# -eq 1 && echo "$@" || echo "$IP")
API_PORT=$((1024 + RANDOM + (RANDOM % 2) * 30000))
KEYS_PORT=$((1024 + RANDOM + (RANDOM % 2) * 30000))
bash -c "$(curl -sSL https://github.com/Jigsaw-Code/outline-server/raw/master/src/server_manager/install_scripts/install_server.sh)" \
  install_server.sh \
  --hostname="${PUBLIC}" \
  --api-port="${API_PORT}" \
  --keys-port="${KEYS_PORT}"

# Create a task on startup
cat >/usr/local/bin/vpn.sh <<EOL
#!/bin/sh
log() { echo "\$(date) - \${1}" >> /var/log/vpn.log; }
log "Boot up"; sleep 10
# Enable BBR to improve network performance
/usr/sbin/sysctl net.core.default_qdisc=fq
/usr/sbin/sysctl net.ipv4.tcp_congestion_control=bbr
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
ip route add table 128 default via ${GATEWAY}
# Check health
while :
do
  sleep 10; ping -q -w 5 1.1.1.1 && continue
  log "Lost connection"
  log "Try to reconnect NordVPN"; timeout 10s nordvpn connect && continue
  log "Try to restart NordVPN's services"; \
    timeout 30s systemctl restart nordvpn.service &&
    timeout 30s systemctl restart nordvpnd.service &&
    log "The services have successfully restarted" &&
    continue
  log "Reboot the server"; /usr/sbin/reboot --force
done
EOL
chmod +x /usr/local/bin/vpn.sh
echo "@reboot sh /usr/local/bin/vpn.sh >/dev/null 2>&1" | crontab -

# TODO: Remove after fixing the bug of NordVPN 3.11.0
# Create a temporary task to fix freezing of NordVPN
# (approximately, each 4 hours 20 minutes). Details,
# reasons and solutions can be found here:
# - https://forum.manjaro.org/t/nordvpn-bin-breaks-every-4-hours/80927
# - https://aur.archlinux.org/packages/nordvpn-bin#comment-829416
# Commands to uninstall the temporary task:
#   rm /usr/local/bin/fix-vpn.sh
#   echo "@reboot sh /usr/local/bin/vpn.sh >/dev/null 2>&1" | crontab -
cat >/usr/local/bin/fix-vpn.sh <<EOL
#!/bin/sh
log() { echo "\$(date) - \${1}" >> /var/log/vpn.log; }
log "Recreate connection"; nordvpn connect
EOL
chmod +x /usr/local/bin/fix-vpn.sh
crontab -l | {
  cat
  echo "0 */4 * * * sh /usr/local/bin/fix-vpn.sh >/dev/null 2>&1"
} | crontab -

# Notify about following actions
info "Configure Outline Manager and run: nordvpn login && reboot"
