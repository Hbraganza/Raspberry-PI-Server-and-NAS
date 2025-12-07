# Section 2) Rsync Incremental Backup Setup

This section is to setup up an automated incremental backup on a different device using rsync on your local network i.e. LAN. It is not currently setup for backup over the internet.

For this backup setup to work it assumes that the Raspberry Pi Gen 2 has been setup properly if not please refer to section 1 of [Backup Device Setup](https://github.com/Hbraganza/Raspberry-PI-Server-and-NAS/blob/main/Raspberry-Pi-Gen-2-Backup/Setup.md)

---

### 1) Create SSH public Key with Backup Device

Run the following on the Raspberry Pi
```
ssh-keygen
```

NOTE: Do this under as the user not as root. Files will then be found in /home/user/.ssh/

Then copy the public key to the device you are backing up either by usb transfer or with the following command

```
ssh-copy-id username@device_IP_or_hostname.local
```
NOTE: doing it over intranet or internet is not as secure as by usb transfer which I recommend however, public keys are public for a reason so will not compromise security

---

### 2) Download/Create the Backup Bash Script

Create your own incremental backup script using rsync or you can download and edit the Github one with:

```
sudo wget -P /path/to/chosen/directory/ https://raw.githubusercontent.com/Hbraganza/Raspberry-PI-Server-and-NAS/refs/heads/main/Raspberry-Pi-5-8GB-Server-NAS/Backupscript.sh
```

Now change the ownership to the user and give the file executable permissions with:

```
sudo chown user:user Backupscript.sh
sudo mod 770 Backupscript.sh
```

---

### 2.1) Edit the Backup Bash Script

If you have downloaded the script then edit the script with `vim` or `nano`.

Edit the following variables to match your criteria:

```
SOURCE="/path/to/source/directory" #the location of the files that will be backedup
DESTINATION="/path/to/backup/directory" #where to backup to on the backup device
SSHKEY="ssh -i /path/to/private/key" #the ssh privatekey command to the backup device
SSHDEVICE="user@device_IP_or_name" #the user you are going to ssh into
DIRECTORIES=("user_1" "user_2" "etc") #due to size of server rsync needed to be broken down to the different user directories setup in the source
SNAPSHOTNAME="Backup_$(date +%F_%H-%M-%S)" #snapshot name
RETENTION_POLICY=56 #backups older than 56 days will be deleted
```

NOTE: for the DIRECTORIES variable it is recommended that they match the sambashare directories to make setup easier and less need to edit the file

NOTE 2: Instructions from here assume that the script was downloaded if you created your own script then it is still possible to follow along but there maybe slight differences

---

### 3) Test the Backup Script

Test the backup script by executing it:

```
Backupscript.sh
```
NOTE: To properly test it is reccomended that you keep a few files outside of the first test to test the incremental backup and DO NOT TEST WITH YOUR MAIN SERVER FILES AT FIRST as there is a risk of deletion, corruption or more create a copy or some test files and try with them first.

The first run will do a full backup and should see a `latest` and `snapshots` directory on the backup device. If you run `ls -l` in that directory the `latest` will show it pointing to another directory. then add some additional files to the source and run it again. This will run faster and should only download the additional files. Once done change directory to the old backup and run `ls -l` in the old backup directory there files will list the number 2 indicating it has 2 hard links.

---

### 4) setup a Cron Job

To automate the backup on regular intervals do the following in user not as root:

```
crontab -e
```

Once in edit the file at the bottom with the following example.

```
0 2 * * 0 /path/to/backup/script.sh
```
`0 2 * * 0` represents the time interval to run the command. This time represents 2am on a sunday if you wish for another time you can use this [crontab calculator](https://crontab.guru) resource to get the desired time interval.
