# Testing and interoperability

Lower Sideband uses deterministic unit, compatibility, simulation, bundle, and platform-build checks.

## Fast local checks

```sh
Scripts/check-repository.sh
swift test
```

The Swift Testing suite covers persistence migrations, cryptographic vectors, packet framing, announces, links, tokens, tunnels, Resources, LXMF, telemetry, plugins, Opus/Codec2 voice, RNode, transport forwarding, outbox recovery, CloudKit merges, and UI-facing store behaviour.

Run a focused test by name:

```sh
swift test --filter nativeTransportInstance
swift test --filter RNode
swift test --filter Voice
```

## Application builds

macOS:

```sh
xcodebuild -project MacSideband.xcodeproj -scheme SidebandMac \
  -destination 'platform=macOS' -derivedDataPath .build/test-macos \
  CODE_SIGNING_ALLOWED=NO build
```

iOS Simulator:

```sh
xcodebuild -project MacSideband.xcodeproj -scheme SidebandIOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/test-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Use separate derived-data directories when builds overlap.

## Bundle validation

```sh
Scripts/validate-ios-app.sh 'generic/platform=iOS Simulator'
```

This verifies bundle identifiers and versions, required Info.plist declarations, privacy manifests, embedded framework metadata, and absence of Python files or Python-linked binaries.

## Upstream compatibility fixtures

Pinned upstream submodules provide reference implementations. Some test vectors were generated from Python Reticulum/LXMF/Sideband and are checked by native Swift tests.

The optional telemetry generator requires a Python environment capable of importing the pinned Sideband source:

```sh
Scripts/verify-python-telemetry.py
```

This developer tool is not part of either application bundle.

## RNode

```sh
Scripts/test-rnode.sh protocol
Scripts/test-rnode.sh apps
Scripts/test-rnode.sh all
```

The dedicated `ReticulumKitTests` suite verifies every official RNode command byte, exhaustive KISS escaping, arbitrary TCP fragmentation, exact configuration vectors, firmware comparison, the 508-byte MTU, all reference telemetry, 10,000 deterministic fuzz cases, real local Network.framework TCP reconnects, radio-busy polling, and 2,500 flow-controlled packet loopbacks. Physical hardware acceptance remains necessary for RF performance, power-cycle behaviour, BLE restoration, serial quirks, and real firmware bootloaders.

## Delivery acceptance

The automated two-app runner builds both clients, launches them with separate
identities and requires delivery proofs, ordering and de-duplication in both
directions:

```sh
Scripts/run-delivery-soak.sh <simulator-udid> <mac-lxmf-id> <sim-lxmf-id> automatic 100
Scripts/run-delivery-soak.sh <simulator-udid> <mac-lxmf-id> <sim-lxmf-id> local 100
Scripts/run-delivery-soak.sh <simulator-udid> <mac-lxmf-id> <sim-lxmf-id> public 100
```

For explicit local/public endpoints, set `SIDEBAND_SOAK_HOST` and
`SIDEBAND_SOAK_PORT`. The runner does not modify DNS.

For end-to-end testing between two app instances:

1. Use distinct identities and confirm each app announces.
2. Record connection, path, and interface state on both endpoints.
3. Send uniquely numbered messages in both directions.
4. Count valid delivery proofs—not only queued or transmitted UI states.
5. Repeat over local TCP, public TCP, propagation delivery, and radio where available.
6. Include network changes, reconnects, stale-path recovery, relaunch, and iOS suspension.
7. Verify duplicates are suppressed and messages remain ordered and durable.

No finite test establishes “100% reliable” networking. Report the exact topology, message count, proof count, retries, failures, and elapsed time.

## Manual GitHub Actions

The `Apple builds` workflow is intentionally triggered only with `workflow_dispatch`. Commits and pull requests do not automatically consume GitHub Actions minutes. A maintainer can start the full verification workflow when useful.
