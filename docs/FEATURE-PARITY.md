# Native feature coverage

This is the current, evidence-based coverage matrix for the native Swift
applications. It is intentionally not called “complete parity”: a transport is
only marked complete when the Apple app can configure it, exchange Reticulum
packets over it, recover from disconnects, and has automated or live
interoperability evidence.

The detailed upstream comparison and exact pinned versions are in
`UPSTREAM-PARITY-AUDIT-2026-07-28.md`.

## Application features

| Area | Status | Native coverage |
| --- | --- | --- |
| LXMF messaging | Complete | Opportunistic, direct-link and propagation delivery; proofs, retries, stamps, tickets, ratchets, replies, reactions and commands |
| Attachments | Complete | Standard LXMF file/image fields plus linked Reticulum Resource transfers, integrity checks, resume windows and bounded storage |
| Voice | Complete | Codec2/Opus voice messages and LXST calls with call history and jitter buffering |
| Identity and contacts | Complete | Keychain identity, contact links/QR, verification, encrypted import/export and conversation naming |
| Telemetry and maps | Complete | Canonical and unknown sensors, collector streams, trails, geospatial calculations and validated offline tiles |
| Sync and migration | Complete with platform limits | End-to-end encrypted CloudKit snapshots, assets, tombstones and read-only Python Sideband SQLite import |
| Plugins | Deliberately different | App-Store-safe native/declarative, permission-scoped plugins replace downloaded executable Python |
| Background reception | Platform-limited | Content-free CloudKit wakes and bounded refresh; arbitrary immediate Reticulum ingress still depends on iOS scheduling or an operator wake service |

## Reticulum transports

| Interface | Runtime | Configuration model | Evidence | Status |
| --- | --- | --- | --- | --- |
| TCP client | macOS/iOS | Yes | Unit, simulator, LAN and public-Internet interoperability | Complete |
| TCP server | macOS/iOS | Core API | Unit and native forwarding tests | Core complete; settings UI pending |
| Shared Instance | macOS/iOS | Yes | Local TCP/HDLC tests | Complete |
| AutoInterface | macOS; restricted on iOS | Yes | Authentication, expiry and peer tests | Complete where multicast is permitted |
| UDP | macOS/iOS | Core API | Datagram/IFAC tests | Client complete; listener configuration pending |
| WebSocket client | macOS/iOS | URL override and portable profile | MeshChatX-compatible binary packet tests | Complete |
| WebSocket server | — | Profile only | — | Not implemented |
| HTTP tunnel client | macOS/iOS | URL override and portable profile | MeshChatX-compatible HDLC POST/poll tests | Complete |
| HTTP tunnel server | — | Profile only | — | Not implemented |
| RNode BLE | macOS/iOS | Yes | Protocol simulator and loopback | Complete |
| RNode TCP/Wi-Fi | macOS/iOS | Yes | Protocol simulator and loopback | Complete |
| RNode serial | macOS | Yes | Protocol simulator and loopback | Complete |
| RNodeMulti virtual ports | — | Profile only | Reference protocol audited | Not implemented |
| Generic KISS / AX.25 KISS | macOS | Core API | Framing, commands and chunk tests | Complete core; advanced UI pending |
| Pipe | macOS | Core API | Process lifecycle and HDLC tests | Complete core; settings UI pending |
| I2P | — | SAM command model only | Command validation tests | Not implemented end-to-end |
| Backbone connector/listener | — | Profile only | TCP transport does not implement Backbone identity semantics | Not implemented |
| Weave | — | Frame codec only | Bounds and frame tests | Not implemented end-to-end |

## External acceptance still required

- Physical RNode and bootloader acceptance per supported board.
- iOS multicast entitlement behaviour on real signed devices.
- Long-running public-Internet tests across independently operated transports.
- Operator-controlled gateway, propagation-node and optional APNs wake-service
  availability.

Public gateways are bootstrap infrastructure, not a central account service,
and no community-operated endpoint can be guaranteed by the app.
