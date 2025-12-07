# Section 1) Raspberry Pi 2 — 6TB Backup Setup

This guide walks through setting up a Raspberry Pi 2 as a backup system using a 6TB HDD with rsync. It assumes Windows for flashing and SSH from your PC. When completed, this will contain the setup method for the automated backup using rsync and the touch screen for the dashboard and photo display system.

- OS: Raspberry Pi OS Lite (32-bit)
- Boot media: 32GB microSD
- Storage: 6TB HDD via powered USB-to-SATA adapter

Before you start, set up SSH keys on Windows. See: [SSH With Public Key on Windows (OpenSSH)](https://github.com/Hbraganza/Family-Home-Server-and-NAS/blob/The-backup-script/SSH-With-Public-Key-Setup/Setup.md).

---

### Equipment used

- Raspberry Pi 2
- 6TB HDD
- 17W micro-USB power supply
- Powered USB‑to‑SATA converter/enclosure
- 32GB microSD card
- Powered USB port

---

## Steps For The Backup Setup

### 1) Flash Raspberry Pi OS and preload your SSH public key

Use Raspberry Pi Imager:

1. Select Raspberry Pi OS Lite (32-bit).
2. Press Ctrl+Shift+X for Advanced options.
3. In Services: Enable SSH and choose “Allow public-key authentication only”.
4. Paste the contents of your public key into the SSH key box.
	- SSH guide: SSH-With-Public-Key setup
5. Set a hostname (e.g., backup-pi.local) and Wi‑Fi/Ethernet as needed.
6. Write to the microSD.

---

### 2) First boot and SSH in

Insert the microSD into the Pi, connect network and power, then from Windows:

```powershell
ssh -i "C:\\Users\\<You>\\.ssh\\id_<mykey>" <user>@backup-pi.local
# or use the IP address
ssh -i "C:\\Users\\<You>\\.ssh\\id_<mykey>" <user>@<pi_ip>
```

Update base packages:

```bash
sudo apt update && sudo apt -y full-upgrade
```

Note: The root user is used a lot for this setup. Therefore, you may find it easier to run the command:

```
sudo su
```

This command will put you as the root user, thus making all commands run as the root user without sudo. This is only recommended if you know what you are doing; otherwise, you can cause serious issues, such as untrusted programs running in root privilege or making directories with the wrong permissions.

---

### 3) Install required packages

```bash
sudo apt install -y vim wakeonlan rsync parted
```

Notes:
- `wakeonlan` is for sending WoL packets to other devices from the Pi.
- `smartmontools` helps check HDD health.
- `parted` handles >2TB partitioning (GPT).

---

### 4) Attach the HDD and identify the device

Plug in your powered USB-to-SATA adapter with the HDD attached.

List disks:

```bash
sudo fdisk -l
```

Find your drive path, e.g., `/dev/sda` (device) and later `/dev/sda1` (partition).

---

### 5) Partition the disk (GPT for >2TB)

For disks larger than 2TB use GPT label and create one NTFS partition:

```bash
sudo parted /dev/sda
(parted) mklabel gpt
(parted) mkpart primary ntfs 0% 100%
(parted) print
(parted) quit
```

Adjust `/dev/sda` if your device letter differs. Confirm the new partition appears as `/dev/sda1` (or similar).

---

### 6) Format the partition (NTFS)

Create an NTFS filesystem on the new partition. The tool is `mkfs.ntfs`:

```bash
sudo mkfs.ntfs -f /dev/sda1
```

Tip: You can add a label, e.g. `-L BACKUP6TB`.

---

### 7) Create mount point and mount

```bash
sudo mkdir -p /mnt/nasdata
sudo mount -t ntfs /dev/sda1 /mnt/nasdata
lsblk -f
```

You should see `/dev/sda1` mounted at `/mnt/nasdata` and filesystem type `ntfs`.

---

### 8) Configure a static IP

To do this find the IP and the DNS IP which was done when the [pi-hole](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/Raspberry-Pi-Gen-1-Pi-Hole/Setup.md) was setup in section 1. The DNS will be the pi-hole IP.

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
