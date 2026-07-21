# Native feature parity

This document records the completed native parity pass against the pinned
Python Sideband reference. “Native” means the distributed Apple applications
perform the work in Swift/C without loading Python.

| Area | Native coverage | Verification |
| --- | --- | --- |
| LXMF anti-spam and forward secrecy | Stamps, delivery tickets, rotating retained ratchets, announce advertisement and enforcement | Deterministic stamp/ticket/ratchet tests and signed payload fixtures |
| Identity and profile portability | Keychain identity replacement, Base32 private identity compatibility, passphrase-authenticated encrypted archives and validated snapshot restore | Corruption, wrong-passphrase, round-trip and Python identity tests |
| Low-bandwidth audio | Official Codec2 1.2.0 at 700C–3200 bit/s for LXMF voice messages and LXST calls; native Opus remains available | Every supported Codec2 mode creates, encodes, decodes and frames in the test suite; both Apple targets link the XCFramework |
| Telemetry and maps | Extended environmental/motion sensor values, scheduling, exclusions, safe MQTT records, trails and validated offline tile packages | Canonical sensor, unknown-sensor, geospatial and offline-package tests |
| Reticulum interfaces and services | TCP client/server, UDP, AutoInterface, RNode/KISS, shared instance, I2P SAM and Weave framing | Wire-format, bounds, interface-mode, forwarding and simulated transport tests |
| Plugins | Compiled permission-scoped APIs plus bounded declarative JSON plugins with no downloaded code execution | Schema, permission, template, timeout, audit and command safety tests |
| RNode lifecycle and presentation | BLE/Wi-Fi/USB transports, configuration, metrics, framebuffer/ROM, signed catalogues, verified downloads, configuration archives and pluggable flashing | Protocol simulator, high-volume loopback, catalogue signature, digest, hardware-match and archive tests |

## Boundaries that are not app-code parity gaps

- APNs wake delivery needs an operated provider and remains subject to iOS
  scheduling.
- Public gateways and propagation nodes are external, independently operated
  infrastructure.
- RF performance, BLE restoration and bootloader flashing require physical
  hardware acceptance on each supported RNode family.
- Downloaded executable Python plugins are intentionally replaced by
  App-Store-safe native/declarative plugins.
- Legacy raw identities and structured archives import natively. Direct
  conversion of every historical Python SQLite schema revision remains a
  compatibility extension rather than a runtime dependency.

See `PORTING.md` for the detailed capability table and `docs/TESTING.md` for
the live acceptance matrix.
