# Native porting status

Lower Sideband is a clean native Swift adaptation. The distributed macOS, iOS, and iPadOS targets do not load the Python Sideband, Reticulum, or LXMF codebases at runtime.

Status labels:

- **Native:** implemented in Swift and covered by automated tests.
- **Partial:** useful native coverage exists, but upstream breadth or live interoperability work remains.
- **External:** requires infrastructure, entitlement, hardware tooling, or an operator service outside the app.
- **Planned:** not yet implemented.

## Application and data

| Upstream capability | Native implementation | Status |
| --- | --- | --- |
| Conversations, messages, drafts, replies, reactions, search | Models, `SidebandStore`, SwiftUI views | Native |
| Local SQLite state | Versioned encrypted snapshots with atomic writes and rolling recovery | Native replacement |
| Legacy identity/profile portability | Authenticated encrypted archives plus raw Python identity import | Native |
| Legacy Sideband SQLite history import | Validated snapshot/conversation import path; direct SQLite conversion | Partial |
| Contacts, names, notes, tags, appearance, trust | Encrypted models, fingerprints, contact links/QR | Native |
| Attachments and inline images | Encrypted storage and Reticulum Resources | Native; ongoing live matrix |
| Backups and structured conversation archives | Validated versioned import/export | Native |
| Multi-device sync | App-encrypted private CloudKit records/assets | Native |
| Notifications and background refresh | UserNotifications, BGTaskScheduler, silent-wake client | Native/External |

## Reticulum

| Capability | Native implementation | Status |
| --- | --- | --- |
| HDLC/KISS framing and packet parsing | `HDLC`, `KISSModem`, `ReticulumPacket` | Native |
| Identity, signatures, encryption, hashes | CryptoKit/Security plus Ed25519 package | Native |
| Announces and destination derivation | `ReticulumAnnounce`, builder and validation | Native |
| Paths, requests, expiry, interface affinity | `ReticulumPathTable`, interface pool | Native |
| Links, proofs, tokens, keepalive, tunnels | Native Reticulum link/session types | Native |
| Resources and segmented transfer | Native advertisement/request/part/hash-map/proof pipeline | Native |
| TCP client and automatic gateway selection | Network.framework pool and health ranking | Native |
| Bonjour and signed interface discovery | Local discovery and validated dynamic interfaces | Native |
| AutoInterface | Authenticated beacon and UDP data plane | Native; iOS entitlement-limited |
| IFAC and interface modes | Native KISS/interface configuration and forwarding policy | Native |
| macOS Transport Instance | Validated routes, forwarding, reverse/link routes, loop suppression | Native |
| UDP, TCP server and shared instance | Native service/interface types | Native core; settings/live matrices ongoing |
| WebSocket and HTTP tunnel clients | Native MeshChatX-compatible transports | Native and unit tested |
| I2P, Backbone, RNodeMulti, Weave and server extensions | Portable profiles or framing helpers | Partial; see `docs/FEATURE-PARITY.md` |

## LXMF and Sideband workflows

| Capability | Native implementation | Status |
| --- | --- | --- |
| LXMF MessagePack, IDs, signatures, fields | Native encode/decode and reference vectors | Native |
| Direct and opportunistic delivery | Native router with proofs and retry state | Native |
| Propagation-node upload/download | Discovery, selection, sync, acknowledgement | Native |
| Commands and telemetry requests | Typed LXMF command fields | Native |
| Telemetry sensors and relay | Canonical sensor maps with lossless unknown sensor preservation | Native |
| Telemetry history/map/CSV/GPX | Native collectors, MapKit, export | Native |
| Low-bandwidth voice messages | Native Opus and official Codec2 700–3200 bit/s encode/decode | Native |
| LXST real-time calls | Link-authenticated Opus/Codec2 audio, jitter buffer, CallKit | Native; background wake external |
| Paper/offline messages | Encrypted contact and message links/QR | Native |
| Python plugin system | Permission-scoped compiled native plugin APIs | Native replacement |
| Downloaded executable plugins | — | Explicit non-goal |

## Interfaces and hardware

| Capability | Native implementation | Status |
| --- | --- | --- |
| RNode BLE | CoreBluetooth transport and restoration | Native |
| RNode Wi-Fi/TCP | Network.framework transport | Native |
| RNode USB serial | macOS serial transport | Native |
| Generic serial/KISS modem | macOS transport | Native |
| RNode radio config and metrics | KISS commands and Network Status UI | Native |
| Beacon/callsign and framebuffer/display | Native scheduler and binary protocol | Native |
| ROM and firmware inspection | Native reads and metadata validation | Native |
| Firmware flashing | Signed catalogues, digest-verified downloads, configuration archives, pluggable flasher | Native framework; physical bootloader acceptance required |

## Platform and infrastructure gaps

- A production APNs provider is required to wake eligible suspended iOS clients; Apple still controls delivery timing.
- Physical iOS AutoInterface multicast requires Apple's restricted entitlement.
- Public gateways and propagation nodes are independently operated and cannot be treated as guaranteed service.
- Live cross-version tests must continue as upstream protocols evolve.
- Platform-specific RNode bootloader tools are required after the app enters firmware update mode.

See [Architecture](docs/ARCHITECTURE.md), [Networking](docs/NETWORKING.md), and the [Roadmap](docs/ROADMAP.md) for design details and remaining priorities.
