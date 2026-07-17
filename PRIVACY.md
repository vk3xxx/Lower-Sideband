# MacSideband Privacy Policy

Effective date: 18 July 2026

MacSideband is a native Reticulum and LXMF messaging application provided by Mark Beacham. Privacy is a core design requirement: the app does not require an account, does not include advertising or third-party analytics, and does not sell personal information.

## Data the developer collects

The developer does not collect message contents, contacts, attachments, voice recordings, precise location, usage analytics, advertising identifiers, or diagnostic data from the app.

MacSideband stores its application state and attachments in encrypted form on the device. Reticulum and LXMF identity keys are stored in the Apple Keychain.

## Messages and network operation

Messages, attachments, voice traffic, contact information, and optional telemetry are sent only when the user chooses to communicate with another destination. Message and attachment contents are protected by Reticulum/LXMF cryptography in transit.

MacSideband can connect through local or public Reticulum gateways. A gateway operator or Internet service provider may observe ordinary network metadata such as IP addresses, connection times, and traffic volume. Gateway operators are independent of MacSideband and have their own policies. They should not receive plaintext message content from encrypted Reticulum links.

## iCloud sync

iCloud sync is optional. When enabled, conversation state and attachments are stored in the user's private CloudKit database. MacSideband encrypts CloudKit payloads with AES-GCM before upload using key material held in the user's synchronizable Keychain. Apple processes iCloud data under the user's Apple account and Apple's privacy terms.

## Device permissions

MacSideband requests access only when a relevant feature is used:

- Camera: scan contact and encrypted paper-message QR codes.
- Microphone: record voice messages and participate in encrypted voice calls.
- Location: attach current location telemetry when the user explicitly chooses to share it.
- Local network: discover and connect to Reticulum gateways and peers.
- Notifications: alert the user to incoming activity when enabled.

The user can change these permissions in Apple Settings.

## Data retention and deletion

Users control their local conversations, messages, attachments, call history, and telemetry. These can be deleted in the app. Removing the app deletes its local application data subject to Apple's device backup and Keychain behaviour. Users who enabled iCloud sync can manage iCloud data through their Apple account and devices.

## Children

MacSideband is not directed to children under 13. The app does not knowingly collect children's personal information.

## Changes

Material changes to this policy will be published at this URL with a revised effective date.

## Contact

Privacy questions can be sent to sepus@hotmail.com.
