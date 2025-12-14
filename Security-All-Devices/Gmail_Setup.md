# Email Setup with Gmail OAuth

This is the guide to setting up the email system that will be called for the backup system and ransomware checker. This will assume the use of gmail and I recommend checking out this answer on [Stackoverflow](https://stackoverflow.com/questions/37201250/sending-email-via-gmail-python) as the script is based off this and the step 1 set up process is identical.


### 0) Setup a Gmail account

This is required to use googles gmail API if you wish to use an existing account you can but I would recommend a fresh account dedicated to the server.

---

### 1) Turn on the Gmail API
Follow the instructions below on a computer or device that you have access to a web browser on.

![Instructions](https://i.sstatic.net/ICIXt.png)

---

### 2) Setup Python Environment On Computer

As some of the devices used are headless do the following on your computer before transferring to the server.

Create a python environment in the same directory you will run your python script with the following command:
```
python3 -m venv path/to/directory/<nameofenv>
```

Source the environment with:
```
source /path/to/directory/<nameofenv>/bin/activate
```

Install the following packages:
```
pip install --upgrade google-api-python-client
pip install httplib2 oauth2client
```

---

### 3) Download and Run the Python Script

Download the python script from

```
wget /path/to/directory https://raw.githubusercontent.com/Hbraganza/Raspberry-PI-Server-and-NAS/refs/heads/main/Security-All-Devices/Email_Sender.py
```

Take the `client_secret.json` file and save it in the same directory as the environment and gmail python script.

Now run the script. By running the following:

```
python3 /path/to/directory/Email_Sender.py --subject "Authorisation" --body "This is for first time Authorisation"
```

You will receive a url use that in a web browser to do the first authorisation. This process generates a .json token typically at `~/.credentials/gmail-python-email-send.json`

Copy or transfer the `client_secret.json` and `~/.credentials/gmail-python-email-send.json` to the different server devices. while keeping the structure of `~/.credentials/gmail-python-email-send.json` the same for each user on the device using the email sender.

---

### 4) Repeat Step 2 and 3 With The token

So when the `client_secret.json` and `~/.credentials/gmail-python-email-send.json` are transferred to the new devices and insure that `client_secret.json` is in the same directory and environment as the `Email_Sender.py` script.