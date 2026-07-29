# Networking and automatic discovery

Lower Sideband runs a native Reticulum/LXMF stack and keeps connection management in the background. The conversation UI reports useful state without presenting routine reconnect failures as modal alerts.

## Automatic connection order

Automatic mode is the default on macOS, iOS, and iPadOS:

1. A user-configured endpoint, when present
2. Previously successful safe local endpoints
3. Bonjour services on the local network:
   - `_reticulum._tcp`
   - `_rns._tcp`
   - `_sideband._tcp`
4. Authenticated Reticulum interface-discovery announces
5. Validated community directory endpoints, then built-in public bootstrap
   endpoints and an optional public override

IPv6 is preferred when available and IPv4 remains a fallback. Hostname resolution is delegated to Network.framework; the application does not alter system DNS configuration.

## Route and delivery state

These states are deliberately distinct:

- **Connected:** a transport socket is active.
- **Route available:** a current path exists for the destination.
- **Link active:** an authenticated encrypted link was established.
- **Queued:** the message is durable but has not yet obtained delivery evidence.
- **Sent:** transport accepted the packet; final delivery may still await proof.
- **Delivered:** valid delivery evidence was received.

Reticulum is delay tolerant. Offline destinations, expired paths, radio duty-cycle limits, public-gateway congestion, and suspended iOS apps can delay delivery.

## Interfaces

| Interface | macOS | iOS/iPadOS | Purpose |
| --- | :---: | :---: | --- |
| TCP client | Yes | Yes | Local or Internet Reticulum gateway |
| WebSocket client | Yes | Yes | Raw Reticulum packets over `ws`/`wss` |
| WebSocket server | Yes | No | Native RFC 6455 binary Reticulum listener |
| HTTP tunnel client | Yes | Yes | HDLC packets over HTTP POST/poll |
| HTTP tunnel server | Yes | No | Native bounded POST/poll session listener |
| Bonjour discovery | Yes | Yes | Local TCP gateway discovery |
| AutoInterface | Yes | Limited | Authenticated local multicast/UDP peers |
| RNode Bluetooth LE | Yes | Yes | Direct LoRa radio |
| RNode Wi-Fi/TCP | Yes | Yes | Network-connected RNode |
| USB serial RNode | Yes | No | Direct macOS serial radio |
| Generic serial/KISS/AX.25 KISS | Yes | No | Serial modem interfaces with READY flow control and AX.25 UI envelopes |
| UDP client and listener | Yes | Yes | Datagram listener/forwarder with optional IFAC |

The macOS interface editor exposes the native TCP server as a normal
ReticulumKit transport. Operators can choose the bind address, port, Reticulum
mode, IFAC credentials and a bounded client limit. The settings list reports
the active listener, connected clients and packet/byte counters without
requiring a separate Reticulum process.
| Weave TCP endpoint | Yes | Yes | Device Control Link discovery, connection and packet lifecycle |
| Pipe | Yes | No | External packet process |
| Transport Instance | Yes | No | Forward routes between active Mac interfaces |

Physical RNodeMulti hardware acceptance, long-running public-I2P acceptance and
physical Weave-switch/serial-TNC acceptance remain tracked gates, not silently
mapped to ordinary TCP. The real-router I2P gate can be enabled with
`SIDEBAND_EXTERNAL_I2P_SAM_HOST` and `SIDEBAND_EXTERNAL_I2P_SAM_PORT`.

Physical iOS multicast behaviour requires Apple's restricted multicast entitlement. The distributed app does not claim unsupported entitlement access.

## Interface modes and IFAC

Reticulum interface modes control forwarding boundaries between access, gateway, roaming, boundary, and full/internal interfaces. Lower Sideband applies these modes when selecting transport forwarding. IFAC credentials can be configured for compatible interfaces and are never shown in privacy-safe diagnostics.

## Public infrastructure

Public endpoints are bootstrap infrastructure, not a central account service.
Lower Sideband can read the same submitted/discovered community directory used
by MeshChatX. Directory results are constrained to the expected HTTPS service,
validated, deduplicated and limited to three live candidates. Known endpoints
remain as fallback. Availability and policy are controlled by independent
operators, and no public endpoint is guaranteed.

For reliable mobile operation, propagation nodes provide store-and-forward
delivery while iOS is suspended. Lower Sideband coalesces CloudKit silent
wakes, background refresh and network-required processing tasks, establishes a
usable propagation link before polling, and then drains the encrypted outbox.
Wake timing remains subject to iOS scheduling.

## Diagnostics

Network Status exposes the active connection policy, interfaces, packet counts, known paths, announces, propagation state, RNode metrics, and Transport Instance state. Its copyable report is designed to omit private identity keys and message contents.

When diagnosing asymmetric delivery, verify that each client has a current direct path and that a gateway's TCP server interface is configured to forward between clients. A stale path can outlive a socket and should be re-requested rather than assumed valid.
