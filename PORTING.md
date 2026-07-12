# Porting map

| Upstream area | Swift destination | Status |
| --- | --- | --- |
| `sideband/core.py` conversation/message state | `SidebandCore` models and store | First milestone |
| Kivy conversation/message screens | `SidebandMac` SwiftUI split view | First milestone |
| SQLite state | Codable atomic application-support snapshot | First milestone; SQLite migration later |
| Reticulum TCP/HDLC and packet parsing | `ReticulumTCPInterface`, `HDLC`, `ReticulumPacket` | Implemented, unit tested |
| Reticulum identity keys, hashes and signatures | `ReticulumIdentity` using CryptoKit | Implemented, Python-vector tested |
| TCP configuration, packet counters and announce capture | Network panel and `SidebandStore` | Implemented |
| Announce parsing, signatures and destination derivation | `ReticulumAnnounce` | Implemented, Python-vector tested |
| Path-request packet generation | `ReticulumPathRequest` | Implemented, Python-layout tested |
| Validated route selection, pending requests and expiry | `ReticulumPathTable` | Implemented |
| Bonjour LAN gateway discovery | `LANGatewayDiscovery` | Implemented for three service names |
| AutoInterface group, authenticated beacons, multicast listener and peer expiry | `AutoInterfaceDiscovery` | Active discovery implemented; UDP data pending |
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
| Attachment metadata and durable local storage | `Attachment`, `AttachmentStore` | Implemented; Resource transfer pending |
| Reticulum routing/announces/link | Native Swift transport engine | In progress |
| `LXMF.LXMRouter` | Native Swift LXMF router | Core direct, opportunistic and propagation delivery implemented; resources pending |
| Identity and cryptography | CryptoKit-backed identity primitives | Implemented for current transport scope |
| Telemetry, maps, audio, voice | Platform services behind shared protocols | Planned |

## Recommended implementation sequence

1. Cross-check the implemented TCP/HDLC framing and packet parser against a live shared Reticulum instance.
2. Port identity, hashes and announces, then link establishment and encrypted resources.
3. Implement MessagePack plus LXMF message packing/signature verification.
4. Add LXMRouter delivery methods and receipts, then connect it to `MessageTransport`.
5. Migrate the upstream Sideband SQLite schema and import existing desktop data.
6. Add attachments, QR links, telemetry/maps, audio and LXST in that order.

Avoid embedding Python in the product target: it would make the macOS prototype quick but would create a dead end for iOS sandboxing and distribution.
