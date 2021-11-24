# NordVPN Gateway

If you cannot access [NordVPN](https://nordvpn.com/) directly or do not have stable connection, but you do love their
great protection including hiding your IP address and other cool features, you can place NordVPN connection
behind [Outline](https://getoutline.org/) and/or [Cloudflare for Teams](https://www.cloudflare.com/teams/). Just create
a gateway by using this tool on your server!

## Usage

### Install

1. Make some preparations:
    1. Buy a subscription for [NordVPN](https://nordvpn.com/).
    3. Optionally, install Outline Manager in order to have a possibility to generate and manage keys. Install Outline
       Client App in order to have a possibility to connect your devices to a server that you will create later. Links
       to download the Outline Manager and Outline Client App [can be found here](https://getoutline.org/).
    2. Optionally, get a free account for [Cloudflare for Teams](https://www.cloudflare.com/teams/) in order to use your
       server as a gateway.
    4. Create a new server based on Ubuntu using [DigitalOcean](https://digitalocean.com/) or another similar service.

2. Connect to the server via SSH and log in as root if needed:

   ```sudo --login```

3. Upgrade the server:

   ```apt update && apt upgrade -y```

4. Configure the server and follow further instructions:

   ```bash -c "$(curl -sSL https://github.com/give-me/vpn/raw/master/install.sh)"```

Later, you can find open ports by running ```ss --processes --listening --tcp``` if you have forgotten them. In order to
change configuration, just repeat the second and fourth steps of this guide.

### Update

In order to update this tool to the latest version, just repeat the second and fourth steps of this guide.

### Uninstall

In order to uninstall this tool, just run ```/opt/vpn-behind-outline/bin/remove.sh``` as root (do not forget to
disconnect VPN to keep a connection via SSH to the server after uninstalling this tool).