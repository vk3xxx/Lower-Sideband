# Security policy

## Supported versions

Lower Sideband is under active development. Security fixes are applied to the latest source and current TestFlight build; older development builds are not maintained.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to **sepus@hotmail.com**. Do not open a public issue for a vulnerability that could expose identities, message content, key material, attachment data, network infrastructure, or another user.

Include, when safe:

- affected version and build number;
- macOS, iOS, or iPadOS version and device type;
- a concise reproduction sequence;
- observed and expected behaviour;
- privacy-safe logs or diagnostics;
- whether the issue is already being exploited.

Do not send real private keys, decrypted personal messages, live access tokens, or credentials. A synthetic test identity and redacted packet capture are preferred.

## Security model

- Reticulum/LXMF private identities are stored in the Apple Keychain.
- Local application state and attachment payloads are encrypted at rest.
- Optional CloudKit records are encrypted by the app before upload.
- Incoming packets, archives, attachments, contact links, telemetry, and plugin commands are validated and bounded.
- Remote plugin commands require explicit enablement and contact authorisation.
- Public gateways transport Reticulum traffic but can observe ordinary network metadata.

No software or network is perfectly secure. Lower Sideband is not intended for emergency, life-safety, or classified communication. See [PRIVACY.md](PRIVACY.md) for data-handling details.
