#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

API_PORT=5934
KEYS_PORT=443

# Check that a domain provided
test $# -eq 0 && echo DOMAIN MISSED && exit 1

# Calculate variables
DOMAIN=${@}
IP=`dig +short ${DOMAIN}`
CIDR=`ip route | grep / | grep ${IP} | awk '{print $1}'`
GATEWAY=`ip route show 0.0.0.0/0 | awk '{print $3}'`
DEV=`ip route show 0.0.0.0/0 | awk '{print $5}'`

# Print variables
echo "IP: ${IP}, CIDR: ${CIDR}, GATEWAY: ${GATEWAY}, DEV: ${DEV}"

# Install Docker
which docker >/dev/null \
|| curl -sSL https://get.docker.com/ | sh

# Install NordVPN
which nordvpn >/dev/null \
|| curl -sSL https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Install and run Outline
docker ps | grep shadowbox > /dev/null \
|| bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)" \
install_server.sh \
--hostname=${DOMAIN} \
--api-port=${API_PORT} \
--keys-port=${KEYS_PORT}

# Configure NordVPN
nordvpn whitelist remove all
nordvpn whitelist add port 22
nordvpn whitelist add port ${API_PORT}
nordvpn whitelist add port ${KEYS_PORT}
nordvpn whitelist add subnet ${CIDR}

# Create a task on startup
cat >/usr/local/bin/vpn.sh <<EOL
#!/bin/sh
sleep 10
nordvpn set autoconnect on
nordvpn set killswitch on
nordvpn set dns 1.1.1.1
nordvpn set technology NordLynx
nordvpn connect || exit 1
ip rule add from ${IP} table 128
ip route add table 128 to ${CIDR} dev ${DEV}
ip route add table 128 default via ${GATEWAY}
EOL
chmod +x /usr/local/bin/vpn.sh
echo "@reboot sh /usr/local/bin/vpn.sh >/dev/null 2>&1" | crontab -

# Notify about following actions
echo "Configure Outline Manager and run: nordvpn login && reboot"