# Sideband Swift

Native Swift/SwiftUI port of [Sideband](https://github.com/markqvist/Sideband), beginning with macOS and structured for a later iOS target.

## Current status

This milestone is a buildable native macOS application with a shared iOS-compatible core. It includes the conversation/message model, LXMF destination validation, durable local storage, native Reticulum transport, and cryptographically verified LXMF delivery.

The native network slice includes Reticulum-compatible HDLC framing, incremental TCP stream decoding, packet header parsing, CryptoKit identity primitives, cryptographic announce validation and a Network.framework TCP interface. The Network panel accepts a Reticulum TCP Server Interface host and port, reports live connection state and packet counts, and captures announce destination hashes in the sidebar. Validated announces retain their public identity, application data and ratchet key.

The Network Status panel can discover Bonjour-advertised `_reticulum._tcp`, `_rns._tcp`, and `_sideband._tcp` gateways on the LAN. A conventional Reticulum TCP Server Interface does not advertise these records automatically, so manual IPv4 or IPv6 host/port configuration remains available. Native AutoInterface supports authenticated multicast peer discovery and the UDP data plane.

Live interoperability is implemented for direct links, opportunistic single-packet delivery, propagation-node upload/download, and native Resource transfers with acknowledgements and deduplication. The app periodically synchronizes with the configured propagation node while active and resumes on foreground activation. On iOS, private Reticulum and LXMF identities are stored in the Keychain. Voice, telemetry, maps, QR transport, hardware interfaces, and plugins remain future work.

Network reliability includes receipt timeouts with delivery fallback, exponential reconnect backoff, live system reachability, IPv6 preference with IPv4 fallback, and relaunch recovery for unproved outbound messages. Verified incoming messages can generate opt-in local notifications. iOS background refresh coordinates propagation sync.

Attachments use native Reticulum Resource advertisements, part requests, hash-map updates, encrypted parts, multi-segment sequencing, proofs and cancellation. Incoming segments are staged on disk, image attachments render inline with downsampled thumbnails and full-size previews, and interrupted transfers recover or clean up safely. Selection rejects duplicates, enforces per-file and combined-size limits, and reports import failures without silently dropping files.

The SwiftUI client includes durable drafts, transcript sharing, message search, drag-and-drop attachment import, route/link actions, conversation pinning, archiving, blocking, notification controls, history cleanup, and failed-outbox retry. Portable `sideband://contact/` links can be copied, shared, imported when creating conversations, and rendered as QR codes. Python-generated wire fixtures cover the Resource negotiation formats; live attachment interoperability with upstream Sideband remains an active validation target.

## Build and run

Requires Xcode 16 or newer and macOS 14 or newer.

```sh
swift test
swift run SidebandMac
```

The shared `SidebandCore` target supports macOS 14 and iOS 17. The executable target is the macOS SwiftUI application.

## Source snapshot

`Sideband-Upstream/` is a shallow checkout of upstream tag `1.9.8`, commit `8601d84580341f2c499041615d772610edb9eaab`. It is kept as a porting reference and retains its own Git history.

Protocol references are also pinned in `Reticulum-Upstream/` and `LXMF-Upstream/`; their individual licences apply.

## Licensing

The upstream application is licensed CC BY-NC-SA 4.0. This adaptation is provided under the same terms; see `LICENSE` and `NOTICE`.
