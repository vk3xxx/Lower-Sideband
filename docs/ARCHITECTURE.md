# Architecture

Lower Sideband is a native Swift application with a shared protocol/state core and a shared SwiftUI application layer for macOS, iOS, and iPadOS.

## Component map

```text
SwiftUI application
  ├─ conversations, composer, maps, telemetry, calls, network status
  └─ platform adapters: audio, location, notifications, lifecycle
                         │
                         ▼
SidebandStore (@MainActor)
  ├─ encrypted persistence and CloudKit merge coordination
  ├─ conversation, outbox, delivery, attachment, and call state
  ├─ automatic interface selection and path maintenance
  └─ plugin permission and audit policy
                         │
          ┌──────────────┴──────────────┐
          ▼                             ▼
LXMF                                   Reticulum
  messages and fields                    packets and HDLC/KISS
  direct/opportunistic delivery          identities and announces
  propagation sync                       paths, links, proofs, tokens
  Resources and attachments              tunnels and transport mode
  telemetry and voice                    TCP, AutoInterface, RNode
```

## Targets

### `ReticulumKit`

`Sources/ReticulumKit` is a standalone Swift framework and Swift Package
library for reusable Reticulum networking. It owns every Reticulum socket,
wire codec and interface lifecycle, including TCP, WebSocket, HTTP tunnel, UDP,
I2P, Weave, AutoInterface, RNode, serial, KISS and AX.25 KISS. Its RNode host
runtime includes official command framing, incremental stream decoding, radio
configuration and telemetry, bounded `CMD_READY` flow control, lifecycle-safe
Network.framework TCP and shared transport contracts. It has no dependency on
`SidebandCore` or Python.

### `SidebandCore`

`Sources/SidebandCore` contains platform-neutral application and LXMF models:

- orchestration of the ReticulumKit identities, packets, links, paths,
  resources and configured interface runtime;
- LXMF packing, signing, direct/opportunistic/propagation delivery, commands, telemetry, attachments, and voice payloads;
- encrypted persistence, attachment storage, CloudKit merge models, notifications, and background coordination;
- plugin manifests, permissions, service lifecycle, telemetry providers, execution limits, and audit records.
- observed-topology graph construction, filtering, and deterministic layout for the Reticulum network map.

The Xcode project creates separate iOS and macOS framework targets from the same source tree and links the platform-specific `ReticulumKit` framework.

### Shared SwiftUI application

`Sources/SidebandMac` predates the iOS target name but is shared by both platforms. Conditional compilation is used only where an Apple framework or capability differs, such as AppKit/UIKit, serial devices, CallKit, or audio routing.

## Network pipeline

1. Interface bytes arrive through a configured ReticulumKit transport.
2. HDLC/KISS framing produces bounded Reticulum packets.
3. Packet headers, lengths, contexts, hashes, and transport fields are validated.
4. Announces are signature-checked before they can update paths or identities.
5. Destination packets are dispatched to link, proof, path, Resource, propagation, or LXMF handlers.
6. Outgoing LXMF delivery chooses an authenticated direct link, opportunistic packet, or propagation node according to route state and policy.
7. Delivery state advances only after valid protocol evidence; connectivity alone is not reported as message delivery.

The network map is a read-only projection of this live pipeline. It joins the
local identity, active interfaces, validated path-table entries, next-hop
transport identities, discovered destinations, conversations, and the selected
propagation node. It never claims to show unobserved portions of the global
Reticulum network. Graph construction, filtering, and layout live in
`SidebandCore`; SwiftUI Canvas supplies platform-native rendering and
interaction on Mac, iPhone, and iPad.

On macOS, optional Transport Instance mode can forward validated routes between active interfaces. It applies hop/header rewriting, reverse-path and link-route tracking, interface-mode boundaries, and packet-hash loop suppression. iOS remains an endpoint.

## Persistence and synchronisation

`SidebandStore` serialises a versioned application snapshot. Before writing, the snapshot is validated and encrypted. Writes are atomic and retain a rolling previous copy. Corrupt primary data is quarantined and recovery uses the last valid snapshot.

Attachment payloads are encrypted separately and referenced by validated relative identifiers. Optional CloudKit sync stores encrypted records and assets in the user's private database. Route discoveries and live socket state are device-local; conversations and portable message state are mergeable.

## Trust boundaries

The following inputs are always treated as untrusted:

- network frames and announces;
- contact links and QR payloads;
- conversation archives and backups;
- attachment metadata and file names;
- telemetry sensor maps;
- remote commands and plugin arguments;
- CloudKit records from another device.

Validation occurs before state mutation. Collections, strings, payloads, retries, timeouts, and histories have explicit bounds to limit resource exhaustion.

## Dependency boundary

Distributed targets do not embed Sideband, Reticulum, LXMF, or a Python runtime. The upstream repositories are pinned Git submodules used for protocol study and developer-only fixture generation.

The only Swift Package Manager runtime dependency is [`AndrewBarba/ed25519`](https://github.com/AndrewBarba/ed25519), used for Ed25519 operations not supplied consistently by the minimum Apple deployment targets. Apple CryptoKit and Security frameworks provide the remaining platform cryptography and key storage.
