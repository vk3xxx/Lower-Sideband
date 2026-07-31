# Testing and interoperability

Lower Sideband uses deterministic unit, compatibility, simulation, bundle, and platform-build checks.

## Fast local checks

```sh
Scripts/check-repository.sh
swift test
```

The Swift Testing suite covers persistence migrations, cryptographic vectors, packet framing, announces, links, tokens, tunnels, Resources, LXMF, telemetry, plugins, Opus/Codec2 voice, RNode, transport forwarding, outbox recovery, CloudKit merges, and UI-facing store behaviour.

Network-map tests verify direct and multi-hop graph construction without
invented links, ancestor-preserving search filters, and deterministic finite
layout for 1,500 observed destinations.

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

## Apple UI reliability

The Xcode project contains dedicated UI-test targets for iPhone/iPad and
macOS. Every run launches against an isolated temporary store, retains
screenshots, and writes an `.xcresult` bundle containing failures and
attachments:

```sh
Scripts/run-ui-reliability-suite.sh iphone
Scripts/run-ui-reliability-suite.sh ipad
Scripts/run-ui-reliability-suite.sh mac
Scripts/run-ui-reliability-suite.sh all
```

Override simulator destinations with `SIDEBAND_UI_IPHONE_DESTINATION` and
`SIDEBAND_UI_IPAD_DESTINATION`; these variables also accept a connected-device
destination such as `platform=iOS,id=<device-identifier>`, so the identical
journey can run on physical hardware. Results default to
`.build/ui-reliability/`.

Settings → Diagnostics also provides a non-destructive recovery drill. It
validates the current snapshot, encrypted round-trip, atomic write/readback,
and authenticated tamper rejection. Snapshot imports first create an encrypted
rollback checkpoint that can be restored from the same screen.

Each device can export a signed acceptance report. Import the Mac, iPhone and
iPad reports on one device to review the consolidated Apple platform matrix,
then export the complete campaign as one portable file. Every contained report
is verified before any import is committed, modified or forged reports are
rejected, and the matrix only completes when all three physical platforms pass
the same application build.

Deferred-send scheduling preserves the actual earliest message deadline and
coalesces later requests behind it. iOS still chooses when a background task
runs, but the app no longer adds a fifteen-minute delay to a nearer deadline.

## Bundle validation

```sh
Scripts/validate-ios-app.sh 'generic/platform=iOS Simulator'
```

This verifies bundle identifiers and versions, required Info.plist declarations, privacy manifests, embedded framework metadata, and absence of Python files or Python-linked binaries.

## Upstream compatibility fixtures

Pinned upstream submodules provide reference implementations. The formal
matrix refuses to run unless the exact audited tags are checked out:

```sh
Scripts/run-upstream-interoperability-matrix.sh fixtures
Scripts/run-upstream-interoperability-matrix.sh live
Scripts/run-upstream-interoperability-matrix.sh all
```

Pinned versions, exact commits and minimum live evidence are defined once in
`Support/UpstreamCompatibility.json`. Run
`Scripts/audit-upstream-releases.py --local-only` to verify the checked-out
references. A separate scheduled/manual GitHub workflow checks upstream tags
and publishes a report; it does not run builds for normal commits and never
updates a pin automatically.

The fixture profile verifies the imported Python versions, regenerates the
Sideband telemetry fixture and runs the complete native test suite. The live
profile runs distinct Swift and stock Python identities over a local Reticulum
TCP server, requires delivery proofs in both directions, echoes standard LXMF
fields, transfers exact 1 MiB files/images and forces bounded reconnects. The
default live gate sends 25 messages each way, attaches data every fifth message
and reconnects every seventh message. Every run writes machine-readable JSON
and separate logs beneath `.build/upstream-matrix/`.

Some test vectors were generated from Python Reticulum/LXMF/Sideband and are
also checked directly by native Swift tests.

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

### Public-Internet production certificate

Public-Internet acceptance is fail-closed. Capture completed Internet-only soak
reports over at least two independently described routes, with at least 2,500
messages each way per route, deterministic 1 MiB files/images, reconnects,
delivery proofs, zero missing or duplicate messages, correct order, and no
delivery timeouts. Then issue a machine-readable certificate:

```sh
Scripts/certify-public-internet.sh \
  .build/linux-mac-soak-route-a.json \
  .build/linux-mac-soak-route-b.json
```

The validator hashes every source report and refuses incomplete, local,
single-route, under-count, corrupt-attachment, timeout, duplicate, ordering, or
proof-deficient evidence. Thresholds can only be deliberately changed through
`SIDEBAND_CERT_MIN_MESSAGES`, `SIDEBAND_CERT_MIN_ROUTES`, and
`SIDEBAND_CERT_MAX_TIMEOUTS`. This certification tooling is read-only and never
changes DNS or network configuration.

## Manual GitHub Actions

The `Apple builds` workflow is intentionally triggered only with `workflow_dispatch`. Commits and pull requests do not automatically consume GitHub Actions minutes. A maintainer can start the full verification workflow when useful.
