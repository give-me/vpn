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

   ```sudo su -```

3. Upgrade the server:

   ```apt update && apt upgrade -y```

4. Configure the server by one of the following commands:

   ```curl -sSL https://github.com/give-me/vpn/raw/master/install.sh | bash``` to access by a default ip-address

   or

   ```curl -sSL https://github.com/give-me/vpn/raw/master/install.sh | bash -s -- 1.2.3.4``` – by a custom ip-address

   or

   ```curl -sSL https://github.com/give-me/vpn/raw/master/install.sh | bash -s -- example.com``` – by a domain name

5. Finish configuration of the server:
    1. Copy a green string that was generated by Outline Server, and past the string into Outline Manager installed in
       accordance with the first step of this guide (the string is similar to *{"apiUrl":"...","certSha256":"..."}*).
    2. Log you in NordVPN and restart the server:
       ```nordvpn login && reboot```
    3. Generate a key with Outline Manager, and connect your device with Outline Client App and the key.

Later, you can find open ports by running ```ss --processes --listening --tcp``` if you have forgotten them.