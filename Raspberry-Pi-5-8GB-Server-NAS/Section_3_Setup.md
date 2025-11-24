# Section 3) VPN server Setup

This section is to setup the vpn to be able to remote in to from outside of your local network using a VPN. The VPN used for this guide is OpenVPN and installed with PiVPN. This guide assumes the setup is on the same machine that you use samba to access the (Raspberry Pi 5). If the VPN server is being setup on a different device please refer to openvpn documentation and adjust accordingly.

This will not be a complete setup guide as it requires the setup of portforwarding and setting up a domain or dynamic dns (DuckDNS is reccommended) while setting up the VPN. Which setup processes are different depend on your router. In the guide it will mention when to setup portforwading and dynamicdns to ensure security is maintained during the setup process.

Lastly this assumes that you have setup a static IP for the device that the VPN server will be on. If not please refer to [Section 1](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/Raspberry-Pi-Gen-1-Pi-Hole/Section_1_Setup.md).

---

### 1) Setup a Dynamic DNS or Domain

First setup up a dynamic DNS (DynDNS) or domain and link it with your routers public IP. Your router will explain how this is done and you can find your public IP by searching "Whats my public IP". 

As mentioned before DuckDNS is a good reccommendation but other domain or DynDNS providers work as well. Once the DynDNS is setup then link it to your router's IP.

---

### 2.1) Install and setup PIVPN

Run the following command on the Pi

```
sudo curl -L https://install.pivpn.io | bash
```
This will then ask you to setup a static IP as the IP has already been set select "Yes" if this is not done then select "No" and follow the instructions.

---

### 2.2) Select a User

It will now prompt you to select a user if you have more than one user you will have multiple options. For this set up "pi" user was used.

---

### 2.3) VPN Selection

It now asks you to select a VPN to use either WireGuard or OpenVPN. In this case select OpenVPN

---

### 2.4) Default Settings

It then provides a couple settings that it recommends as default. If they are not suitable select "No" and adjust accordingly. Otherwise select "Yes" which is recommended.

---

### 2.5) Pick the Port

It then asks about which port to default connect to. The recommendation is the default of 1194 however if your router already is using that port change it to something else. 

Note: Remember the number used for later!!

---

### 2.6) Select DNS Provider

This gives you some options to select for DNS provider you'd like to use. As the Pi-hole is setup select custom.

---

### 2.7) Provide the DynDNS or Domain

Now input the DynDNS or Domain used to link to the routers IP.

---

### 2.8) (Optional) Enable Unattended Upgrades

The last prompt asks if you want to enable unattended upgrades this is highly recommended to keep upto date with the latest cyber security software.

---

### 2.9) Reboot

Reboot the device to finish the install

---

### 3) Portforward

Go to your router and portforward it to the Pi's IP using the portnumber that you provided in the setup. This is different for each router so search up how to do it.

---

### 4.1) Create a VPN profile

To use the VPN profiles need to be created to make the certificates which can be done by the following:

```
pivpn add
```

Put in a name, this will be the name of the file.

Put in a certificate timelimt which defaults to 1080 days. If you wish to increase it is recommended not to go above 10 years, 3560 days.

This generates a file in the user's home which can be found at:

```
/home/<user_listed_in_2.2>/ovpns/<name>.ovpn
```

---

### 4.2) Edit the file for Split Tunneling and Removing Verbosity

Edit the `.ovpn` file using a text editor and set verb to 0 to remove verbosity.

To enable Split Tunneling, where the device only uses the VPN to connect to the server and not use the VPN when connecting to a different domain or the internet. At the bottom of the file add the following:

```
route-nopull
route xxx.xxx.xxx.0 255.255.255.0 vpn_gateway
```

Where xxx.xxx.xxx are the first 3 parts of you local IP

---

### 5) Transfer the File to the Devices Remoting in

Take the `.ovpn` file and transfer it to the devices you want to use to remote into the vpn server. 

It is highly recommended that this is done physically and not over the internet. Though if the internet is required then it encrypt the files.

---

### 6) Connecting by OpenVPN

Install OpenVPN on all devices that will be remoting in.

Open the OpenVPN application and follow it through. Import the `.ovpn` file to the application and connect. Using the password you created when creating the vpn user.

### 7) Connecting to the Samba Share

To connect to the Samba share the local IP will not work.

Instead to connect go into the OpenVPN application and turn on the VPN connection and find your private IP that it provides usally listed as `10.xx.xx.x`. where x is the IP numbers

The VPN has created it's own "private network" with the VPN server acting as the "router". So if the Samba share is on the same device as the VPN server the IP to connect to the Samba share is `10.xx.xx.1`. With the login in details to the Samba share being the Samba login credentials setup previously.