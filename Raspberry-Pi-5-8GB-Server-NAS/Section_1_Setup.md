# Section 1) Raspberry Pi 5 (8GB) — 4TB NAS Setup

This guide walks through setting up a Raspberry Pi 5 (8GB) as a home NAS using a 4TB HDD and Samba. It assumes Windows for flashing and SSH from your PC. When completed, this will contain the setup method for the automated backup using rsync and the touch screen for the dashboard and photo display system.

- OS: Raspberry Pi OS (64-bit)
- Boot media: 32GB microSD
- Storage: 4TB NAS HDD via powered USB-to-SATA adapter

Before you start, set up SSH keys on Windows. See: [SSH With Public Key on Windows (OpenSSH)](https://github.com/Hbraganza/Family-Home-Server-and-NAS/blob/The-backup-script/SSH-With-Public-Key-Setup/Setup.md).

---

### Equipment used

- Raspberry Pi 5 (8GB)
- 4TB NAS HDD
- 27W USB‑C power supply
- Powered USB‑to‑SATA converter/enclosure
- 32GB microSD card

---

## Steps For The NAS Setup

### 1) Flash Raspberry Pi OS and preload your SSH public key

Use Raspberry Pi Imager:

1. Select Raspberry Pi OS (64-bit).
2. Press Ctrl+Shift+X for Advanced options.
3. In Services: Enable SSH and choose “Allow public-key authentication only”.
4. Paste the contents of your public key into the SSH key box.
	- SSH guide: SSH-With-Public-Key setup
5. Set a hostname (e.g., nas-pi.local) and Wi‑Fi/Ethernet as needed.
6. Write to the microSD.

---

### 2) First boot and SSH in

Insert the microSD into the Pi, connect network and power, then from Windows:

```powershell
ssh -i "C:\\Users\\<You>\\.ssh\\id_<mykey>" <user>@nas-pi.local
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
sudo apt install -y samba samba-common-bin vim wakeonlan rsync parted
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

Tip: You can add a label, e.g. `-L NAS4TB`.

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

### 9) Create a group and users

Create a group to manage access (example: `nasusers`). Add your admin (not root) user and any other users.

```bash
sudo groupadd nasusers
sudo usermod -aG nasusers <admin>
id <admin>
```
Where `<admin>` is the name of your admin user
Create additional users as needed and add them to the group:

```bash
sudo adduser <user1>
sudo usermod -aG nasusers <user1>
sudo adduser <user2>
sudo usermod -aG nasusers <user2>
```

Note the UID values from `id <admin>` and in the command also the GID for the `nasusers` group to configure fstab.

---

### 10) Configure auto-mount with fstab (NTFS)

Using the partition details, edit fstab:

```bash
sudo vim /etc/fstab
```

Add a line similar to this (replace UUID, uid/gid to match your admin user):

```
\dev\sda1  /mnt/nasdata  ntfs  defaults,uid=<uid>,gid=<gid>,umask=0007  0  0
```

Notes:
- `umask=0007` gives rwx to owner and group, no access to others.
- `uid/gid/umask` options apply to NTFS via ntfs-3g. For ext4, use Linux permissions instead (see note below).

Test before rebooting:

```bash
sudo umount /mnt/nasdata
sudo mount -a
lsblk -f
```

If `mount -a` returns an error, fix `/etc/fstab` immediately. Do not reboot until it mounts cleanly (a bad fstab can prevent boot and will require reflashing the SD card with a new OS).

Ext4 note: If you format the disk as ext4 instead of NTFS, omit uid/gid/umask in fstab and manage permissions with `chown/chmod` on the mounted directory. You will need to create a script that runs on boot to change the ownership, group and permission if you want this automated.

---

### 11) Prepare share directories and permissions

Create private directories per user and a common share, then set ownership to the admin user and group so group members can access:

```bash
sudo mkdir -p /mnt/nasdata/user1 /mnt/nasdata/user2 /mnt/nasdata/common
sudo chown -R <admin>:nasusers /mnt/nasdata
sudo chmod -R 770 /mnt/nasdata
```

`chmod 770` aligns with `umask=0007` in fstab (owner+group full permissions, others none).

---

### 12) Configure Samba

Edit Samba config:

```bash
sudo vim /etc/samba/smb.conf
```

Under `[global]`, ensure at minimum:

```
[global]
	workgroup = WORKGROUP
	security = user
	server smb encrypt = required
```

At the bottom, add private user shares and a common group share. Example:

```
[user1_share]
	path = /mnt/nasdata/user1
	valid users = user1, <admin>
	read only = no
	browsable = yes

[user2_share]
	path = /mnt/nasdata/user2
	valid users = user2, <admin>
	read only = no
	browsable = yes

[common]
	path = /mnt/nasdata/common
	valid users = @nasusers 
	read only = no
	browsable = yes
```

Add Samba passwords for users (separate from Linux account passwords), which will be used to connect to the device:

```bash
sudo smbpasswd -a <admin>
sudo smbpasswd -a user1
sudo smbpasswd -a user2
```

Restart Samba and check status:

```bash
sudo systemctl restart smbd nmbd
sudo systemctl status smbd --no-pager
```

On newer systems, `nmbd` may not be present; `smbd` is sufficient.

---

### 13) Test from another computer

From Windows, map a network drive or connect via Explorer:

```
\\nas-pi.local\user1_share
\\nas-pi.local\common
```

From Android, use a file manager that supports smb protocol. Then select the `network drive` and follow the instructions. 

Be sure to log in with the user's username (set with `adduser`) and the Samba password you set with `smbpasswd`.
