# Section 1) Raspberry Pi Gen 1 — 4GB SD Pi-hole Setup 

This guide sets up a Raspberry Pi Gen 1 as a Pi-hole DNS sinkhole. It assumes you’re using a Windows PC to prepare the SD card and to SSH into the Pi. This will later show the setup method for domainhosting, vpn and porting.

---

### Prerequisites

- Raspberry Pi Gen 1 with 4GB microSD card
- Raspberry Pi OS Lite (32-bit) flashed via Raspberry Pi Imager
- Your SSH key pair ready on Windows
	- See SSH With Public Key on Windows guide for generating and using SSH keys

---

## Pi-Hole Setup

### 1) Flash OS and preload your SSH public key

Using Raspberry Pi Imager on Windows:

1. Choose Raspberry Pi OS Lite (32‑bit).
2. Press Ctrl+Shift+X for Advanced options.
3. Enable SSH and select “Allow public-key authentication only”.
4. Paste your public key into the SSH key box.
5. Set a hostname (e.g., pihole.local) and configure Wi‑Fi/Ethernet.
6. Write the image to the SD card and insert it into the Pi.

Security note: Keep your private key encrypted and backed up. Consider storing a copy on an external drive.

---

### 2) SSH into the device

Find the Pi on your network or use the hostname you set. From Windows PowerShell:

```powershell
ssh -i "C:\\Users\\<You>\\.ssh\\id_<mykey>" <USER>@pihole.local
# or via IP
ssh -i "C:\\Users\\<You>\\.ssh\\id_<mykey>" <USER>@<IP_ADDRESS>
```

Update the system:

```bash
sudo apt update && sudo apt -y full-upgrade
```

Note: the root user is used alot for this setup. Therefore you may find it easier to run the command:

```
sudo su
```

This command will put you as the root user thus making all commands run as root user without sudo. This is only recommended if you know what you are doing otherwise you can cause serious issues such as untrusted programs running in root privialge or making directories with the wrong permissions.

---

### 3) Discover network details (optional but useful)

The Raspberry Pi needs to be setup on a static IP to work with Pi-hole so to find a good IP to go to see active devices on your LAN from a Linux host you can use `nmap`:

```bash
sudo apt install -y nmap
sudo nmap -sn 192.168.1.0/24
```

Replace the subnet with your network (e.g., 192.168.0.0/24). On the Pi itself, get resolver and router info:

```bash
# Current DNS server(s)
cat /etc/resolv.conf

# Default gateway (router IP)
ip r | awk '/default/ {print $3}'
```

---

### 4) Configure a static IP

Once you have a empty IP and gateway and DNS IP details. Set a static IP with `nmtui` (NetworkManager) or classic `dhcpcd` depending on your OS build.

Option A — NetworkManager (nmtui) newer Raspberry Pi OS:

```bash
sudo apt install -y network-manager
sudo nmtui
```

Use “Edit a connection” to set a manual IPv4 address, gateway, and DNS (temporarily use your router or a public DNS until Pi-hole is running). Restart networking after changes.

Option B — dhcpcd.conf older Raspberry Pi OS:

```bash
sudo vim /etc/dhcpcd.conf
```

Add lines like the following (adapt to your interface and network):

```
interface eth0
static ip_address=192.168.1.50/24
static routers=192.168.1.1
static domain_name_servers=1.1.1.1 8.8.8.8
```
note `eth0` is for ethernet connection wifi is `wlan0`
Apply changes with:

```bash
reboot
ip a
```

Note: Make sure the chosen IP is outside your router’s DHCP pool or reserved for the Pi.

---

### 5) Install Pi-hole

Run the official installer:

```bash
curl -sSL https://install.pi-hole.net | bash
```

During setup:

- Choose the network interface you configured.
- Select upstream DNS providers.
- Enable blocking lists as desired.
- Note the web admin URL and password shown at the end.

You can later change settings in `/etc/pihole/` or via the web admin at `http://<pi_ip>/admin`.

---

### 6) Point your router DNS to the Pi-hole

In your router’s DHCP/DNS settings, set the primary and secondary DNS server to the Pi’s static IP. Optionally set the secondary DNS to none or a backup Pi-hole if you have one.

After applying, renew leases or reboot a client device and verify that DNS queries go through Pi-hole.

---

### 7) Verify and maintain

Basic checks:

```bash
# Ensure services are running
sudo systemctl status pihole-FTL --no-pager

# Tail Pi-hole log
sudo tail -f /var/log/pihole.log
```

From a client machine, visit `http://<pi_ip>/admin` to see query logs and dashboards.

Change the web admin password if needed:

```bash
sudo pihole -a -p
```

Keep the system updated periodically:

```bash
sudo apt update && sudo apt -y full-upgrade
```

---


