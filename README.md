# NordVPN behind Outline

If you cannot access [NordVPN](https://nordvpn.com/) directly or do not have stable connection, but you do love their
great protection including hiding your IP address and other cool features, you can place NordVPN connection
behind [Outline](https://getoutline.org/). Just create a gateway by using this tool on your server!

## Usage

1. Make some preparations:
    1. Buy a subscription for [NordVPN](https://nordvpn.com/).
    1. Install Outline Manager in order to have a possibility to generate and manage keys. Install Outline Client App in
       order to have a possibility to connect your devices to a server that you will create later. Links to download the
       Outline Manager and Outline Client App [can be found here](https://getoutline.org/).
    1. Create a new server based on Ubuntu using [DigitalOcean](https://digitalocean.com/) or another similar service.

2. Connect to the server via SSH and log in as root if needed:

   ```sudo --login```

3. Upgrade the server:

   ```apt update && apt upgrade -y```

4. Configure the server by one of the following commands and follow further instructions:

   ```bash -c "$(curl -sSL https://github.com/give-me/vpn/raw/master/install.sh)"``` to access by a default ip-address

   or

   ```bash -c "$(curl -sSL https://github.com/give-me/vpn/raw/master/install.sh)" -- 1.2.3.4``` – by a custom ip-address

   or

   ```bash -c "$(curl -sSL https://github.com/give-me/vpn/raw/master/install.sh)" -- example.com``` – by a domain name

In order to update this tool to the latest version, just repeat the second and fourth steps of this guide. Later, you
can find open ports by running ```ss --processes --listening --tcp``` if you have forgotten them.

In order close or open additional ports, just edit their numbers by running ```nano /opt/vpn-behind-outline/ports``` as
root, whereupon repeat the second and fourth steps of this guide.

In order to uninstall this tool, just run ```/opt/vpn-behind-outline/bin/uninstall.sh``` as root (do not forget to
disconnect VPN to keep a connection via SSH to the server after uninstalling this tool).