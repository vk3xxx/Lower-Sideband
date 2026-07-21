# App Store listing

## Release

- Version: 1.1.0
- Build: 18
- App Store Connect: Build 18 is the corrected archive built with Xcode 26.6 and the iOS 26.5 SDK; build 16 was rejected with `ITMS-90111`
- Price: Free
- Availability: All storefronts, including future storefronts
- Release: Automatically release after App Review approval

## Submission checklist

- Product metadata and screenshots: Complete
- App Privacy and age rating: Complete
- App Store build: Build 18 was uploaded and submitted to App Review on 21 July 2026; status is Waiting for Review
- App Review contact: Complete, including phone number
- EU Digital Services Act status: Non-trader, active
- Content rights: Necessary third-party content rights confirmed by the developer
- User safety: Contacts can be blocked; contacts and individual incoming messages can be reported through a user-reviewed support email that excludes private content and keys by default
- Add for Review: Complete
- Submit for Review: Rejected as Invalid Binary on 19 July 2026; Apple Developer Support contacted for toolchain clarification
- App Review submission ID: `9b40a038-d010-41bc-b292-f0a6f212f283`
- Apple Developer Support case ID: `102946262465`

## Product page

Subtitle:

> Private Reticulum messaging

Promotional text:

> Private, resilient messaging over Reticulum and LXMF with automatic gateway discovery, encrypted attachments, voice notes, calls, telemetry and iCloud sync.

Description:

> Lower Sideband is a native Reticulum and LXMF client for private, resilient communication across local and Internet-connected networks.
>
> Connect without creating an account. Lower Sideband generates your LXMF identity on-device, discovers compatible local gateways automatically, and falls back to public Reticulum gateways when needed.
>
> Features:
> - End-to-end encrypted text messaging
> - Automatic local-first gateway discovery with IPv6 and IPv4 fallback
> - Encrypted image and file attachments
> - Voice notes and encrypted voice calls
> - Contact QR codes, identity fingerprints and trusted-contact verification
> - Optional location and battery telemetry sharing
> - Optional encrypted iCloud sync across your Apple devices
> - Message search, replies, reactions, drafts, archiving and exports
> - Delivery, path and gateway diagnostics
>
> Lower Sideband does not require an account, include advertising, or collect analytics. Your identities are stored in the Apple Keychain, local app data is encrypted, and optional CloudKit payloads are encrypted before upload.
>
> Reticulum is delay tolerant. Delivery time and availability depend on reachable peers, gateways and propagation nodes. Lower Sideband is not an emergency service and should not be relied on for urgent or life-safety communications.

Keywords:

> reticulum,lxmf,encrypted messaging,mesh,privacy,off-grid,voice,telemetry,delay tolerant

- Support URL: https://github.com/vk3xxx/MacSideband-Support
- Privacy policy URL: https://github.com/vk3xxx/MacSideband-Support/blob/main/PRIVACY.md
- Primary category: Social Networking
- Secondary category: Utilities
- Copyright: 2026 Mark Beacham

## App Review

- Contact: Mark Beacham
- Email: sepus@hotmail.com
- Phone: +61 428 091 786
- Sign-in required: No

Review notes:

> Lower Sideband does not require an account or sign-in. On first launch it creates a local LXMF identity and automatically discovers a Reticulum gateway, preferring local gateways and falling back to public Internet gateways. The main interface can be reviewed without another user. To test messaging, use a second Reticulum/LXMF client and exchange the LXMF ID shown at the top of the screen. Camera, microphone, location, notifications and iCloud sync are optional and requested only when their features are used. Network Status provides privacy-safe connection diagnostics. Reticulum delivery can be delay-tolerant and depends on available gateway/path state. The app is not an emergency service.
>
> Safety: A user can block a contact from that contact's conversation menu. “Report Contact” and “Report Message” open a user-reviewed email to support containing only the destination and optional message identifier/date; no message text, attachment, telemetry, contact note, display name or cryptographic key is attached automatically. Reports are reviewed at `sepus@hotmail.com` and safety concerns will receive a timely response.

## Privacy and compliance

- App Privacy: Data Not Collected
- Export compliance: Uses only exempt encryption declared with `ITSAppUsesNonExemptEncryption = NO`
- Content rights: The app has the necessary rights to its content
- Age rating: 13+
- Age-rating capabilities: Messaging and Chat = Yes; Social Media = No (there is no public feed or broad content amplification); User-Generated Content should be answered from Apple’s current questionnaire wording

## Screenshots

- iPhone 6.5-inch: upload the `.jpg` files in `AppStore/Screenshots/iPhone-6.5-inch` (no alpha channel)
- iPad 13-inch: upload the `.jpg` files in `AppStore/Screenshots/iPad-13-inch` (no alpha channel)

Raw simulator captures are intentionally excluded from source control.
