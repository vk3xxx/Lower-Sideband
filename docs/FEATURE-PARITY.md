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
| Reticulum network map | Complete | Live interfaces, observed next-hop transports, direct/multi-hop routes, propagation nodes, route search/filtering and destination actions |
| Sync and migration | Complete with platform limits | End-to-end encrypted CloudKit snapshots, assets and tombstones; read-only Python Sideband preview/import across canonical and historical schemas, including rich LXMF fields, conversation preferences, telemetry and announces with session rollback |
| Plugins | Deliberately different | App-Store-safe native/declarative, permission-scoped plugins replace downloaded executable Python |
| Background reception | Platform-limited | Content-free CloudKit wakes and bounded refresh; arbitrary immediate Reticulum ingress still depends on iOS scheduling or an operator wake service |

## Reticulum transports

| Interface | Runtime | Configuration model | Evidence | Status |
| --- | --- | --- | --- | --- |
| TCP client | macOS/iOS | Yes | Unit, simulator, LAN and public-Internet interoperability | Complete |
| TCP server | macOS/iOS | Unified interface editor with bind address, mode, IFAC, client limit and live peer/traffic diagnostics | Unit, native forwarding and live diagnostics tests | Complete |
| Shared Instance | macOS/iOS | Yes | Local TCP/HDLC tests | Complete |
| AutoInterface | macOS; restricted on iOS | Yes | Authentication, expiry and peer tests | Complete where multicast is permitted |
| UDP | macOS/iOS | Unified interface editor | Bidirectional listener/client and IFAC tests | Complete listener, forwarder and client lifecycle |
| WebSocket client | macOS/iOS | URL override and portable profile | MeshChatX-compatible binary packet tests | Complete |
| WebSocket server | macOS | Unified interface editor | RFC 6455 masked-client and binary-server frame tests | Complete native listener |
| HTTP tunnel client | macOS/iOS | URL override and portable profile | MeshChatX-compatible HDLC POST/poll tests | Complete |
| HTTP tunnel server | macOS | Unified interface editor | Bidirectional POST/poll session tests | Complete native listener |
| RNode BLE | macOS/iOS | Yes via ReticulumKit | Protocol conformance; physical device pending | Implemented, not hardware-certified |
| RNode TCP/Wi-Fi | macOS/iOS | Yes via ReticulumKit | Official vectors, TCP lifecycle, 10k fuzz, 2.5k flow-control soak | Automated production gate complete |
| RNode serial | macOS | Yes via ReticulumKit | Protocol conformance; physical device pending | Implemented, not hardware-certified |
| RNodeMulti virtual ports | `RNodeMultiInterface` | Native virtual-port selection, per-port radio configuration/state, flow control and shared BLE/TCP/serial transport | Exact framing, all 12 virtual ports and simulator coverage | Implemented in ReticulumKit; physical multi-radio device acceptance remains required |
| Generic KISS / AX.25 KISS | macOS | Unified interface editor | Framing, commands, flow control, AX.25 UI and chunk tests | Complete host lifecycle; physical TNC acceptance remains |
| Pipe | macOS | Unified interface editor | Safe process lifecycle, reconnect and bidirectional HDLC echo test | Complete |
| I2P | `I2PInterface` | Native SAM v3 session ownership plus STREAM CONNECT/ACCEPT lifecycle, health probe, timeout and bounded reconnect | Local SAM lifecycle plus optional real i2pd bidirectional acceptance gate | Complete in ReticulumKit; long-running public I2P soak remains operational acceptance |
| Backbone connector/listener | `BackboneInterface` | TCP/HDLC-compatible connector, multi-peer listener and signed discovery transport-identity binding | Live connector/listener packet test and discovery identity validation | Implemented in ReticulumKit |
| Weave | macOS/iOS | Unified interface editor | Bounds, frame and configured-runtime lifecycle tests | Complete TCP endpoint lifecycle; physical switch acceptance remains |

## External acceptance still required

- Physical RNode and bootloader acceptance per supported board.
- iOS multicast entitlement behaviour on real signed devices.
- Long-running public-Internet tests across independently operated transports.
- Operator-controlled gateway, propagation-node and optional APNs wake-service
  availability. iOS now coalesces CloudKit/BGTask wakes and waits for a usable
  propagation link, but the operating system still decides execution time.

Public gateways are bootstrap infrastructure, not a central account service,
and no community-operated endpoint can be guaranteed by the app.

## Upstream regression gate

The repository pins Sideband 2.0.1, Reticulum 1.4.2 and LXMF 1.1.0 as
developer-only references. The automated matrix verifies all native fixtures
and performs live bidirectional delivery with proofs, standard 1 MiB
file/image fields and forced reconnects. The references and Python test tools
are never included in either application bundle.
