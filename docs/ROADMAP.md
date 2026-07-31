# Roadmap

Lower Sideband now covers the main native messaging, network, telemetry, mapping, voice, plugin, and RNode workflows. Remaining work is primarily interoperability breadth, infrastructure, migration, and production hardening rather than basic UI parity.

## Near term

- Keep the completed deterministic upstream matrix current as Sideband,
  Reticulum and LXMF publish new releases.
- Exercise attachments, propagation sync, voice, telemetry and network
  transitions across physical iPhone, iPad and Mac hardware using the
  versioned in-app acceptance workspace. RNode hardware remains a separate
  acceptance track.
- Keep the automated string-catalog, accessibility-identifier, privacy,
  background-mode, MetricKit, serial-test, and Release-build quality gates
  green. Continue native-speaker review, assistive-technology testing, and
  long-running memory/power profiling on physical devices.
- Keep the versioned redacted support-report schema current as new runtime
  health counters are added.
- Keep storage-retention and quota safeguards covered as new message and
  attachment states are introduced.
- Strengthen public endpoint health data and operator documentation without embedding private infrastructure assumptions.
- Keep descriptive/plural-table migration fixtures current as additional
  upstream historical column variants are found.

## Infrastructure-dependent

- Deploy and monitor redundant project-controlled Reticulum gateways and LXMF propagation nodes.
- Operate an optional project-controlled APNs provider for immediate Reticulum ingress; encrypted cross-device CloudKit changes already use CloudKit-operated content-free wakes.
- Add service health and abuse-response procedures suitable for a public production deployment.

## Compatibility extensions

- Expand the tested read-only Python migration matrix if upstream introduces
  table shapes beyond the supported abbreviated and descriptive conversation,
  LXMF-message, telemetry and announce schemas.
- Broaden support for specialised Reticulum interfaces not available through TCP, AutoInterface, RNode, or generic KISS.
- Add physical-board bootloader acceptance evidence for each supported RNode family.

## Explicit non-goals

- Embedding a Python interpreter in iOS or macOS distribution targets
- Claiming guaranteed real-time delivery over delay-tolerant or community-operated networks
- Silent execution of downloaded plugin code
- Treating public community gateways as a guaranteed central service
- Positioning Lower Sideband as an emergency or life-safety system

Roadmap items are directional and do not promise a release date.
