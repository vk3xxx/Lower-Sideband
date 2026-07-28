# Upstream parity audit — 28 July 2026

## Pinned references

| Project | Version inspected | Purpose |
| --- | --- | --- |
| Sideband | 2.0.1 (`2000d81`) | User-facing workflows and LXMF behaviour |
| MeshChatX | 4.8.1 (`4bd787`) | Reticulum interface lifecycle, configuration breadth and transport UX |
| Reticulum | 1.4.2 | Authoritative packet, link, resource and interface semantics |
| LXMF | 1.1.0 | Authoritative message and field semantics |

MeshChatX is used as the practical interface reference requested for this
project. The Reticulum implementation and manual remain authoritative when a
MeshChatX extension and the Reticulum wire protocol differ.

## Changes resulting from this audit

- Added native WebSocket client transport. Each binary WebSocket message is one
  raw Reticulum packet, matching MeshChatX's custom interface.
- Added native HTTP tunnel client transport. Requests and responses carry one
  or more HDLC-framed Reticulum packets, use the
  `RNS-HTTP-Tunnel/1.0` user agent, default to a 100 ms poll and a 4096-byte
  MTU, matching MeshChatX.
- Extended the live interface pool so TCP, WebSocket and HTTP endpoints share
  health state, retry control and packet routing.
- Added a portable, validated interface profile covering the interface catalog
  exposed by MeshChatX, including listener conflict preflight.
- Added validated community interface discovery from MeshChatX's
  `directory.rns.recipes` submitted and discovered feeds. Only HTTPS directory
  responses and safe, enabled TCP/Backbone-without-special-semantics entries
  are accepted; results are deduplicated and bounded to three.
- Kept known bootstrap endpoints as an independent fallback. A directory
  outage therefore cannot prevent automatic connection.
- Corrected previous documentation that inaccurately described I2P SAM and
  Weave framing helpers as complete transports.

## MeshChatX interface comparison

| MeshChatX interface | Lower Sideband result |
| --- | --- |
| AutoInterface | Native implementation present |
| TCP client/server | Native implementation present |
| Shared Instance | Uses native TCP/HDLC connection to the local instance |
| UDP | Native client present; listener/settings breadth remains |
| RNode BLE/TCP/serial | Native implementation present |
| RNodeMulti | Gap: virtual-port selection and per-port configuration |
| Serial, KISS, AX.25 KISS | Native macOS core present; advanced settings breadth remains |
| Pipe | Native macOS core present |
| WebSocket client | Added in this audit |
| WebSocket server | Gap |
| HTTP tunnel client | Added in this audit |
| HTTP tunnel server | Gap |
| I2P | Gap: SAM strings exist but there is no complete session/stream lifecycle |
| Backbone connector/listener | Gap: ordinary TCP must not be labelled Backbone without transport-identity semantics |
| Weave | Gap: codec exists but no complete switch/endpoint lifecycle |

## Prioritised remaining work

1. Complete I2P SAM session, connect/accept and reconnect lifecycle.
2. Implement RNodeMulti virtual-port selection, per-port state and simulator
   coverage.
3. Implement Backbone transport identity and listener semantics from Reticulum
   1.4.2.
4. Add WebSocket and HTTP server modes on macOS.
5. Add a single Apple-style interface editor that exposes only options valid
   for each transport and performs port-conflict checks before saving.
6. Complete UDP listener, advanced KISS/AX.25 and Weave runtime lifecycles.
7. Run physical-device and public-Internet acceptance matrices before moving
   any row from partial to complete.

## Licensing boundary

Sideband is inspected for behavioural compatibility, not copied. MeshChatX's
permissively licensed interface implementations provide a safe practical
reference, while the native implementation in this repository remains original
Swift code.
