# Raspberry Pi Server and NAS
This is the repository showing the setup process and any scripts used to set up our family's Home Server which is made of Raspberry Pi's to replace dropbox. It has a shared file storage area and private sections for file storage. It is also to act as a guide for anyone wanting to set up their own server/NAS but finds the current options lacking, bloated or don't store files how you want them to. The equipment used to set this up is:

## Equipment List
- Raspberry Pi 5 (8GB) - Acting as the Home server and NAS (plans to host touchscreen with dashboard and photo display)
- Raspberry Pi 1 - Acting as the Pi-hole (plans to make it host a domain and VPN for security)
- Raspberry Pi 4 1GB x2 - (plans to be the onsite and offsite backup) 
- My Personal computer - (Plans to remote in for gaming, virtualisation and developer work)
- 4TB NAS HDD - For the Server
- 6TB HDD - (plans for offsite and local Backup)

## Software for setup currently
- Samba protocol (NAS)
- SSH public key protocol
- Pi-Hole Network wide Adblocker
- rsync for backup over local network

---

## Setup Process

To follow/recreate the setup that is used, this repository has been broken down so each directory represents what has been done on each device. In the folder is a setup.md file which explains the steps for setup on that device. The setup.md files are broken down into sections each section is the setup of one part for example set of the NAS or setup of the Backup. This README.MD will provide the overall setup order and links to each of the setup pages. The order is as follows:

- Step 1: For all devices a [SSH public key](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/SSH-With-Public-Key-Setup/Setup.md) was setup
- Step 2: Setup the Pi-Hole (network wide adblocker), follow Section 1 on the [DNS-Server](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/DNS-Server/Section_1_Setup.md).
- Step 3: Setup the NAS/Server, follow Section 1 on the [VPN-Server-NAS](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/VPN-Server-NAS/Section_1_Setup.md).
- Step 4: Setup the local backup, follow Section 1 on the [Local-Backup](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/Local-Backup/Section_1_Setup.md). Then follow Section 2 on the [VPN-Server-NAS](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/VPN-Server-NAS/Section_2_Setup.md).
- Step 5: Setup the VPN server using open VPN by following section 3 on the [VPN-Server-NAS](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/VPN-Server-NAS/Section_3_Setup.md).

These are the steps to setup the core functions of the server. The reamainder are additional features that can be added for security and personal usecases.

- Object detection algorithm for photos and videos and database classification
- Photo frame image selector
- Ransomeware detection system
- Offsite backup
---

## To Do List

- [ ] Setup file system and automated backup system on Pi 5 and Pi 2 for NAS
	- [x] Setup Pi 5 with NAS visability on Linux and Windows using Samba
	- [x] Setup private user sections and shared photo section with admin access to all files
	- [x] Setup Pi 2 to perform smooth easy recovery
	- [ ] Automate weekly backup with Wake-up Over LAN on Pi 2
	- [ ] Setup HDD health monitor with 3 months history saved on the Pi 2 and Pi 5
	- [ ] Setup automated health alert by email

- [ ] Test recovery system and iteration system
	- [x] Revert one file
	- [x] Revert full disk
	- [ ] Full recovery of old data on disk using backup
	- [ ] Test email alert and HDD health monitoring
	- [x] Test file access

- [ ] Build inclosures and tidy cables
	- [x] Build Pi 2 inclosure
	- [ ] Build router cable management system
	- [x] Build Pi 5 inclosure with photo frame

- [ ] Setup file and photo additional file access methods and syncing
	- [x] Setup phone access
	- [x] Setup phone photo syncing to users private space with ability to transfer to shared area
	- [ ] Setup password manager
	- [x] Setup VPN

- [x] Test non-local network access
	- [x] Test it is secure and get checked
	- [x] Setup domain

- [ ] Attach screen to Pi 5 and build photo frame
	- [ ] Attach screen to Pi 5
	- [ ] Setup 6 am to 10 pm photo viewer
	- [ ] Setup dashboard
    - [x] Setup object detection of Humans and animals for photo selection using YOLO or similar

- [ ] Powersaving setup
	- [ ] Setup control of smart plugs for backup systems
	- [ ] Setup idle system for NAS HDD

- [ ] Setup a ransomware detection system

- [ ] Test full system and ensure Pi 1 works when Pi 5 fails and visa versa also check send checks if each other are running
