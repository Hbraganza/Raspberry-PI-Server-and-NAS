#!/usr/bin/env python3

import httplib2
import os
import oauth2client
from oauth2client import client, tools, file
import base64
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from apiclient import errors, discovery
import mimetypes
from email.mime.image import MIMEImage
from email.mime.audio import MIMEAudio
from email.mime.base import MIMEBase

SCOPES = 'https://www.googleapis.com/auth/gmail.send'
CLIENT_SECRET_FILE = 'client_secret.json'
APPLICATION_NAME = 'Gmail API Python Send Email'

def get_credentials():
    home_dir = os.path.expanduser('~')
    credential_dir = os.path.join(home_dir, '.credentials')
    if not os.path.exists(credential_dir):
        os.makedirs(credential_dir)
    credential_path = os.path.join(credential_dir,
                                   'gmail-python-email-send.json')
    store = oauth2client.file.Storage(credential_path)
    credentials = store.get()
    if not credentials or credentials.invalid:
        flow = client.flow_from_clientsecrets(CLIENT_SECRET_FILE, SCOPES)
        flow.user_agent = APPLICATION_NAME
        credentials = tools.run_flow(flow, store)
        print('Storing credentials to ' + credential_path)
    return credentials

def SendMessage(sender, recipients, subject, body):
    credentials = get_credentials()
    http = credentials.authorize(httplib2.Http())
    service = discovery.build('gmail', 'v1', http=http)
    message1 = CreateMessageText(sender, recipients, subject, body)
    result = SendMessageInternal(service, "me", message1)
    return result

def SendMessageInternal(service, user_id, message):
    try:
        message = (service.users().messages().send(userId=user_id, body=message).execute())
        print('Message Id: %s' % message['id'])
        return message
    except errors.HttpError as error:
        print('An error occurred: %s' % error)
        return "Error"
    return "OK"

def CreateMessageText(sender, recipients, subject, body):
    # recipients: list of emails
    to_header = ", ".join(recipients)
    msg = MIMEMultipart()
    msg['Subject'] = subject
    msg['From'] = sender
    msg['To'] = to_header
    msg.attach(MIMEText(body, 'plain'))
    # Gmail API expects a base64url-encoded string, not bytes
    return {'raw': base64.urlsafe_b64encode(msg.as_bytes()).decode('utf-8')}

def main():
    import argparse
    parser = argparse.ArgumentParser(description='Send Gmail text email to multiple recipients')
    parser.add_argument('--sender', required=True, help='Sender Gmail address')
    parser.add_argument('--to', required=True, nargs='+', help='One or more recipient email addresses')
    parser.add_argument('--subject', required=True, help='Email subject')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--body', help='Email body text')
    group.add_argument('--body-file', help='Path to a file whose contents become the email body')
    args = parser.parse_args()

    if args.body_file:
        try:
            with open(args.body_file, 'r', encoding='utf-8', errors='replace') as f:
                body = f.read()
        except Exception as e:
            print(f"Failed to read body file: {e}")
            return
    else:
        body = args.body

    SendMessage(args.sender, args.to, args.subject, body)

if __name__ == '__main__':
    main()