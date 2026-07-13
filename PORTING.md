# Porting map

| Upstream area | Swift destination | Status |
| --- | --- | --- |
| `sideband/core.py` conversation/message state | `SidebandCore` models and store | Implemented for current messaging scope |
| Kivy conversation/message screens | `SidebandMac` SwiftUI split view | Implemented for current messaging scope |
| SQLite state | Codable atomic application-support snapshot | Implemented; SQLite import remains future work |
| Reticulum TCP/HDLC and packet parsing | `ReticulumTCPInterface`, `HDLC`, `ReticulumPacket` | Implemented, unit tested |
| Reticulum identity keys, hashes and signatures | `ReticulumIdentity` using CryptoKit | Implemented, Python-vector tested |
| TCP configuration, packet counters and announce capture | Network panel and `SidebandStore` | Implemented |
| Announce parsing, signatures and destination derivation | `ReticulumAnnounce` | Implemented, Python-vector tested |
| Path-request packet generation | `ReticulumPathRequest` | Implemented, Python-layout tested |
| Validated route selection, pending requests and expiry | `ReticulumPathTable` | Implemented |
| Bonjour LAN gateway discovery | `LANGatewayDiscovery` | Implemented for three service names |
| AutoInterface group, authenticated beacons, multicast listener and peer expiry | `AutoInterfaceDiscovery` | Implemented |
| AutoInterface UDP packet receive/send | `AutoInterfaceDiscovery` data listener | Implemented on port 42671 |
| Link request, link ID and X25519/HKDF key derivation | `ReticulumLinkRequest` | Implemented, Python-vector tested |
| Link proof signature validation and session activation | `ReticulumLinkSession` | Implemented, Python-vector tested |
| Link AES-256-CBC tokens and HMAC authentication | `ReticulumToken` | Implemented, Python-vector tested |
| TCP client tunnel synthesis | `ReticulumTunnelSynthesis` | Implemented, Python-vector tested |
| Encrypted link packets and keepalives | `ReticulumLinkSession` | Implemented, Python-vector tested |
| LXMF MessagePack payload, message ID and signature | `LXMFMessage` | Implemented, Python-vector tested |
| LXMF link identification and propagation list request | `LXMFPropagation` | Implemented, Python-vector tested |
| MessagePack response decoding | `MessagePackDecoder` | Implemented for LXMF response types |
| Recipient identity encryption for propagated LXMF | `ReticulumIdentity.encrypt` | Implemented, Python-vector tested |
| Propagation upload envelope and queued fallback | `LXMFMessage.propagatedEnvelope` | Implemented |
| Propagation download, decrypt, validate, import and acknowledge | `SidebandStore` sync pipeline | Implemented |
| Signed `lxmf.delivery` announce | `ReticulumAnnounceBuilder` | Implemented |
| Incoming link request acceptance and proof | `ReticulumIncomingLink` | Implemented, Python-vector tested |
| Direct and opportunistic inbound LXMF with delivery proofs | `SidebandStore`, `ReticulumProof` | Implemented, live Python interoperability tested |
| Periodic propagation synchronization and lifecycle pause/resume | `SidebandStore` | Implemented |
| iOS private identity persistence | `SecureIdentityStore` | Keychain-backed with legacy migration |
| Receipt timeout and delivery escalation | `SidebandStore` | Implemented |
| TCP reconnect, reachability and dual-stack fallback | `SidebandStore`, `NetworkReachability` | Implemented |
| Relaunch-safe outbound recovery | Codable snapshot recovery | Implemented, tested |
| LXMF announce display names | `LXMFAnnounceInfo` | Implemented, tested |
| Verified incoming local notifications | `LocalNotificationManager` | Implemented, opt-in |
| iOS background propagation refresh | `BackgroundRefreshCoordinator` | Implemented |
| Attachment metadata and durable local storage | `Attachment`, `AttachmentStore` | Implemented |
| Reticulum Resource advertisements, requests, parts, proofs and cancellation | `ReticulumResource*` | Implemented, Python-fixture tested |
| Resource hash-map updates and multi-segment transfer | `ReticulumResourceHashMapUpdate`, segment planner/staging | Implemented |
| Attachment sending, receiving, progress and inline images | `SidebandStore`, SwiftUI attachment views | Implemented for native Swift peers |
| Reticulum routing/announces/link | Native Swift transport engine | Implemented for current TCP and AutoInterface scope |
| `LXMF.LXMRouter` | Native Swift LXMF router | Direct, opportunistic, propagation and attachment Resource delivery implemented |
| Identity and cryptography | CryptoKit-backed identity primitives | Implemented for current transport scope |
| Telemetry, maps, audio, voice | Platform services behind shared protocols | Planned |

## Next priorities

1. Complete live attachment and large-Resource interoperability testing against upstream Sideband and Reticulum.
2. Add migration/import support for existing Sideband SQLite data.
3. Harden iOS background delivery, power use, and network-transition behavior on physical devices.
4. Add QR contact exchange and transport configuration.
5. Port telemetry/maps, audio, LXST, hardware interfaces, and plugins incrementally.

Avoid embedding Python in the product target: it would make the macOS prototype quick but would create a dead end for iOS sandboxing and distribution.
