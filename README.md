# Sideband Swift

Native Swift/SwiftUI port of [Sideband](https://github.com/markqvist/Sideband) for macOS, iPhone and iPad.

## Current status

This milestone includes native macOS and iOS applications backed by the same Swift Reticulum/LXMF core. It includes the conversation/message model, LXMF destination validation, durable local storage, native Reticulum transport, and cryptographically verified LXMF delivery. The shipping application has no Python runtime, Python libraries or external Swift package dependencies.

The native network slice includes Reticulum-compatible HDLC framing, incremental TCP stream decoding, packet header parsing, CryptoKit identity primitives, cryptographic announce validation and a Network.framework TCP interface. The Network panel accepts a Reticulum TCP Server Interface host and port, reports live connection state and packet counts, and captures announce destination hashes in the sidebar. Validated announces retain their public identity, application data and ratchet key.

The Network Status panel can discover Bonjour-advertised `_reticulum._tcp`, `_rns._tcp`, and `_sideband._tcp` gateways on the LAN. A conventional Reticulum TCP Server Interface does not advertise these records automatically, so manual IPv4 or IPv6 host/port configuration remains available. Native AutoInterface supports authenticated multicast peer discovery and the UDP data plane.

Live interoperability is implemented for direct links, opportunistic single-packet delivery, propagation-node upload/download, and native Resource transfers with acknowledgements and deduplication. The app periodically synchronizes with the configured propagation node while active and resumes on foreground activation. On iOS, private Reticulum and LXMF identities are stored in the Keychain. Voice, camera-based QR scanning, hardware interfaces, and plugins remain future work.

Network reliability includes receipt timeouts with delivery fallback, exponential reconnect backoff, live system reachability, IPv6 preference with IPv4 fallback, and relaunch recovery for unproved outbound messages. Verified incoming messages can generate opt-in local notifications. iOS background refresh coordinates propagation sync.

Attachments use native Reticulum Resource advertisements, part requests, hash-map updates, encrypted parts, multi-segment sequencing, proofs and cancellation. Incoming segments are staged on disk, image attachments render inline with downsampled thumbnails and full-size previews, and interrupted transfers recover or clean up safely. Selection rejects duplicates, enforces per-file and combined-size limits, and reports import failures without silently dropping files.

The SwiftUI client includes durable drafts, transcript sharing, message search, drag-and-drop attachment import, route/link actions, conversation pinning, archiving, blocking, notification controls, history cleanup, and failed-outbox retry. Portable `sideband://contact/` links can be copied, shared, imported when creating conversations, opened directly by macOS, and rendered as QR codes. The local display name is configurable and included in LXMF announces and shared contact links.

Network diagnostics can be copied from the status panel without exposing private identity material. Versioned JSON backups can be exported and restored after validation. Every save maintains a rolling copy of the previous valid snapshot; corrupt primary data is quarantined and recovered from that copy silently at launch. Unreferenced attachment files are cleaned conservatively in the background. Python-generated wire fixtures cover the Resource negotiation formats; live attachment interoperability with upstream Sideband remains an active validation target.

Native telemetry now supports the upstream LXMF `FIELD_TELEMETRY` format for timestamp, location, and battery sensors. Location is captured only after an explicit share action, embedded in the encrypted LXMF message, persisted in backups, shown inline, included in transcript exports, and plotted as sent/received history with MapKit. `Scripts/verify-python-telemetry.py` generates the canonical fixture with upstream Python Sideband and checks byte-for-byte compatibility.

## Build and run on macOS

Requires Xcode 16 or newer and macOS 14 or newer.

```sh
swift test
Scripts/verify-python-telemetry.py
swift run SidebandMac
```

To create the launchable application bundle used for local testing:

```sh
Scripts/package-macos-app.sh
open dist/Sideband.app
```

The package script performs a release build and installs the executable plus the tracked `Support/Sideband-Info.plist`, including the `sideband` URL scheme and local-network declarations.

## Build and run on iOS

The checked-in `MacSideband.xcodeproj` contains the `SidebandIOS` application scheme for iOS 17 or newer. It uses the production bundle identifier `com.supes.MacSideband` and the Mark Beacham Individual Apple developer team. Open the project, select an iPhone, iPad or simulator, and run the `SidebandIOS` scheme:

```sh
open MacSideband.xcodeproj
```

To perform clean simulator and generic arm64 device builds, validate required Info.plist declarations and privacy manifests, and prove that the resulting bundles contain no Python artifacts or Python-linked binaries:

```sh
Scripts/validate-ios-app.sh 'generic/platform=iOS Simulator'
Scripts/validate-ios-app.sh 'generic/platform=iOS'
```

The iOS target declares local-network, Bonjour, location, background-refresh and `sideband://` URL handling. `Support/PrivacyInfo.xcprivacy` declares the approved reasons for app-local preferences and attachment staging timestamps.

TCP gateway connectivity works on physical iOS devices. iOS schedules background propagation refresh opportunistically and does not guarantee an indefinitely active TCP socket while the app is suspended. Reticulum AutoInterface multicast on physical devices additionally requires Apple approval for the restricted multicast networking entitlement; the entitlement is intentionally not claimed by the current distribution profile.

## TestFlight

Create a signed release archive and upload it with the Individual team configuration:

```sh
xcodebuild -project MacSideband.xcodeproj -scheme SidebandIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath .build/archives/Sideband.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath .build/archives/Sideband.xcarchive \
  -exportOptionsPlist Support/ExportOptions-TestFlight.plist \
  -exportPath .build/testflight-export \
  -allowProvisioningUpdates
```

The App Store Connect record is named `MacSideband`. Increment `CURRENT_PROJECT_VERSION` before every subsequent upload.

## Native dependency boundary

`Sideband-Upstream/`, `Reticulum-Upstream/` and `LXMF-Upstream/` are pinned reference snapshots. `TestConfig/*.py` and `Scripts/verify-python-telemetry.py` are developer-only interoperability tools. None are referenced by the Xcode targets or included in macOS/iOS bundles.

## Source snapshot

`Sideband-Upstream/` is a shallow checkout of upstream tag `1.9.8`, commit `8601d84580341f2c499041615d772610edb9eaab`. It is kept as a porting reference and retains its own Git history.

Protocol references are also pinned in `Reticulum-Upstream/` and `LXMF-Upstream/`; their individual licences apply.

## Licensing

The upstream application is licensed CC BY-NC-SA 4.0. This adaptation is provided under the same terms; see `LICENSE` and `NOTICE`.
