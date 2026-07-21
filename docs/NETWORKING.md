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
5. Built-in public bootstrap endpoints and an optional public override

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
| Bonjour discovery | Yes | Yes | Local TCP gateway discovery |
| AutoInterface | Yes | Limited | Authenticated local multicast/UDP peers |
| RNode Bluetooth LE | Yes | Yes | Direct LoRa radio |
| RNode Wi-Fi/TCP | Yes | Yes | Network-connected RNode |
| USB serial RNode | Yes | No | Direct macOS serial radio |
| Generic serial/KISS | Yes | No | Compatible modem interfaces |
| Transport Instance | Yes | No | Forward routes between active Mac interfaces |

Physical iOS multicast behaviour requires Apple's restricted multicast entitlement. The distributed app does not claim unsupported entitlement access.

## Interface modes and IFAC

Reticulum interface modes control forwarding boundaries between access, gateway, roaming, boundary, and full/internal interfaces. Lower Sideband applies these modes when selecting transport forwarding. IFAC credentials can be configured for compatible interfaces and are never shown in privacy-safe diagnostics.

## Public infrastructure

Public endpoints are bootstrap infrastructure, not a central account service. Availability and policy are controlled by their independent operators. The app maintains endpoint health, cooldown, and latency history, but no public endpoint is guaranteed.

For reliable mobile operation, propagation nodes provide store-and-forward delivery while iOS is suspended. Silent APNs wake hints can improve sync latency but still require an operator-controlled APNs provider and remain subject to Apple's scheduling.

## Diagnostics

Network Status exposes the active connection policy, interfaces, packet counts, known paths, announces, propagation state, RNode metrics, and Transport Instance state. Its copyable report is designed to omit private identity keys and message contents.

When diagnosing asymmetric delivery, verify that each client has a current direct path and that a gateway's TCP server interface is configured to forward between clients. A stale path can outlive a socket and should be re-requested rather than assumed valid.
