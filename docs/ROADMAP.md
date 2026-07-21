# Roadmap

Lower Sideband now covers the main native messaging, network, telemetry, mapping, voice, plugin, and RNode workflows. Remaining work is primarily interoperability breadth, infrastructure, migration, and production hardening rather than basic UI parity.

## Near term

- Complete extended live interoperability matrices against current upstream Sideband, Reticulum, and LXMF releases.
- Exercise attachments, propagation sync, voice, telemetry, RNode, and network transitions across physical iPhone, iPad, and Mac hardware.
- Expand accessibility audits, localisation preparation, performance profiling, and long-running memory/power tests.
- Strengthen public endpoint health data and operator documentation without embedding private infrastructure assumptions.
- Expand automated migration tests for every persisted snapshot version.

## Infrastructure-dependent

- Deploy and monitor redundant project-controlled Reticulum gateways and LXMF propagation nodes.
- Operate an APNs provider for content-free wake hints and token lifecycle management.
- Add service health and abuse-response procedures suitable for a public production deployment.

## Compatibility extensions

- Import selected legacy Python Sideband SQLite data into the native encrypted store.
- Broaden support for specialised Reticulum interfaces not available through TCP, AutoInterface, RNode, or generic KISS.
- Extend native plugin APIs while retaining App Store sandboxing, explicit permissions, and deterministic reviewability.
- Integrate supported platform-specific firmware flashing tools where this can be done safely and within Apple distribution rules.
- Continue expanding less-common telemetry collectors and renderer types.

## Explicit non-goals

- Embedding a Python interpreter in iOS or macOS distribution targets
- Claiming guaranteed real-time delivery over delay-tolerant or community-operated networks
- Silent execution of downloaded plugin code
- Treating public community gateways as a guaranteed central service
- Positioning Lower Sideband as an emergency or life-safety system

Roadmap items are directional and do not promise a release date.
