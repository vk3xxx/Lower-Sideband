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
| UDP | Native listener, forwarder and client with unified settings |
| RNode BLE/TCP/serial | Native implementation present |
| RNodeMulti | Complete in ReticulumKit: virtual-port selection, independent per-port configuration/state, flow control and simulator coverage. Physical multi-radio hardware acceptance is still required. |
| Serial, KISS, AX.25 KISS | Native macOS lifecycle and advanced unified settings complete; physical acceptance remains |
| Pipe | Complete in the ReticulumKit configured runtime and unified macOS editor |
| WebSocket client | Added in this audit |
| WebSocket server | Native macOS listener complete |
| HTTP tunnel client | Added in this audit |
| HTTP tunnel server | Native macOS listener complete |
| I2P | Complete in ReticulumKit: SAM v3 session ownership, health probe, STREAM CONNECT/ACCEPT, HDLC transport, timeout and bounded reconnect lifecycle, with an optional real-i2pd acceptance gate. |
| Backbone connector/listener | Complete in ReticulumKit: reference-compatible TCP/HDLC connector, spawned peer listener semantics and signed discovery transport-identity binding. |
| Weave | Native TCP endpoint lifecycle complete; physical switch acceptance remains |

## Prioritised remaining work

1. Run physical multi-radio RNodeMulti acceptance on supported hardware.
2. Completed: real-router I2P acceptance gate and in-app SAM diagnostics.
3. Completed: Weave TCP endpoint lifecycle in ReticulumKit.
4. Completed: WebSocket and HTTP server modes on macOS.
5. Completed: one Apple-style interface editor exposing transport-valid
   options with pre-save port-conflict checks.
6. Completed: UDP listener, advanced KISS/AX.25 and Weave runtime lifecycles.
7. Run physical-device and public-Internet acceptance matrices before moving
   any row from partial to complete.
8. Completed: Pipe editor/runtime lifecycle and coalesced iOS background
   propagation wake workflow.

## Licensing boundary

Sideband is inspected for behavioural compatibility, not copied. MeshChatX's
permissively licensed interface implementations provide a safe practical
reference, while the native implementation in this repository remains original
Swift code.
