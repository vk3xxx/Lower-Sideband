# Sideband Swift

Native Swift/SwiftUI port of [Sideband](https://github.com/markqvist/Sideband) for macOS, iPhone and iPad.

## Current status

This milestone includes native macOS and iOS applications backed by the same Swift Reticulum/LXMF core. It includes the conversation/message model, LXMF destination validation, durable local storage, native Reticulum transport, and cryptographically verified LXMF delivery. The shipping application has no Python runtime, Python libraries or external Swift package dependencies.

The native network slice includes Reticulum-compatible HDLC framing, incremental TCP stream decoding, packet header parsing, CryptoKit identity primitives, cryptographic announce validation and a Network.framework TCP interface. The Network panel accepts a Reticulum TCP Server Interface host and port, reports live connection state and packet counts, and captures announce destination hashes in the sidebar. Validated announces retain their public identity, application data and ratchet key.

The app starts gateway discovery and connection automatically. It first tries explicitly configured private IPv6 and IPv4 endpoints, then Bonjour-advertised `_reticulum._tcp`, `_rns._tcp`, and `_sideband._tcp` services and remembers the last successful advertised gateway. Only after local options fail does it open three public community bootstrap entrypoints concurrently, with an optional user-supplied public IPv6 address or DNS hostname placed first. The dual-stack `rns.beleth.net` entrypoint is the first built-in bootstrap, followed by several current public-directory entries. Public hostnames are resolved by Network.framework, which can use IPv6 when offered and fall back to IPv4. Signed `rnstransport.discovery.interface` announces are validated together with their LXMF proof-of-work stamp; safe advertised TCP interfaces are added dynamically, and the public bootstrap sockets are retired after two discovered interfaces are healthy. Routes are retained per interface, path requests and announces cross every healthy reticule, and encrypted link traffic stays pinned to the interface that established the link. Network changes restart the complete local-first selection cycle and restore the public bootstrap set if discovered paths fail. Fresh installs do not embed a private gateway address. Manual configuration remains available in Network Status. Native AutoInterface supports authenticated multicast peer discovery and the UDP data plane.

Live interoperability is implemented for direct links, opportunistic single-packet delivery, propagation-node upload/download, and native Resource transfers with acknowledgements and deduplication. The app cryptographically recognizes `lxmf.propagation` announces, automatically selects the best discovered propagation node, uploads queued messages when direct delivery fails, and pulls waiting messages on foreground, background refresh and remote wake. On iOS, private Reticulum and LXMF identities are stored in the Keychain, and contact cards can be imported with the native camera QR scanner. Native real-time voice calling interoperates with the Python LXST `lxst.telephony` primitive using identity-authenticated Reticulum links and the medium-quality Opus profile.

Native RNode support provides direct LoRa connectivity over Bluetooth LE on iPhone, iPad and Mac, RNode Wi-Fi/TCP on every platform, and USB serial on macOS. It implements upstream KISS framing, detection, firmware checks, radio configuration, flow-safe BLE fragmentation, automatic reconnection, packet routing and radio metrics including RSSI, SNR, battery, temperature, airtime and channel load. Multiple radio and IP interfaces remain live together so Reticulum can retain independent paths. The Network panel supports regional starting presets, manual frequency/bandwidth/SF/CR/power and airtime configuration, hardware blink, and a deterministic 100-packet self-test that needs no radio. Bluetooth central state restoration and the iOS background mode preserve eligible RNode connections within Apple's background-execution limits.

Run `Scripts/test-rnode.sh protocol` for the focused protocol and 100-packet simulated-radio tests, `Scripts/test-rnode.sh apps` to compile both app platforms, or `Scripts/test-rnode.sh` for both. With physical hardware, open Network Status, add or automatically discover the RNode, confirm its firmware and radio metrics appear, use **Blink** to verify the selected device, then exchange messages while watching RX/TX counters and route discovery. Radio frequency, power and airtime settings must match the hardware and local regulations.

Network reliability includes automatic gateway selection, receipt timeouts with delivery fallback, exponential reconnect backoff, live system reachability, IPv6 preference with IPv4 fallback, and relaunch recovery for unproved outbound messages. Connection attempts and maintenance failures remain silent in normal conversation UI and are visible in Network Status. Verified incoming messages can generate opt-in local notifications. iOS background refresh coordinates propagation sync.

Attachments use native Reticulum Resource advertisements, part requests, hash-map updates, encrypted parts, multi-segment sequencing, proofs and cancellation. Incoming segments are staged on disk, image attachments render inline with downsampled thumbnails and full-size previews, and interrupted transfers recover or clean up safely. Native AAC voice notes can be recorded on macOS and iOS, transferred through the same encrypted Resource path, and played or scrubbed inline. Selection rejects duplicates, enforces per-file and combined-size limits, and reports import failures without silently dropping files.

The SwiftUI client includes durable drafts, transcript sharing, structured privacy-safe JSON conversation export, message search, drag-and-drop attachment import, route/link actions, conversation pinning, archiving, blocking, notification controls, unread filtering, history cleanup, and failed-outbox retry. Individual messages can be copied, inspected, deleted, securely forwarded with independent attachment records, or replied to using the upstream LXMF `FIELD_REPLY_TO` and `FIELD_REPLY_QUOTE` wire fields; encrypted reply context is preserved across local storage, CloudKit sync and backups. Discovery results can be sorted and safely pruned without removing active contacts or routing dependencies.

Portable `sideband://contact/` links can be copied, shared, imported when creating conversations, opened directly by macOS, and rendered as QR codes. New contact links include a public identity key that is accepted only when it cryptographically derives the advertised LXMF destination; legacy keyless links remain supported. Contacts expose a full SHA-256 identity fingerprint that can be compared over a separate trusted channel and pinned locally; a later mismatching keyed contact link is rejected. Contact collections can be exported and imported without silently transferring verification trust to a different device. This lets Python-compatible encrypted `lxm://` paper messages be authenticated after exchanging contact QR codes, then generated from sent text or telemetry and imported by link, paste or the native camera scanner without a live network connection. The local display name is configurable and included in LXMF announces and shared contact links.

Voice calls include outgoing route discovery, incoming ringing, answer/decline, busy and timeout handling, mute and hang-up controls, encrypted local/iCloud call history with missed-call status and callback/redial actions, a trusted-contacts-only policy, and native microphone/speaker routing on macOS and iOS. A bounded jitter buffer absorbs ordinary packet timing variation, reprimes cleanly after an underrun and drops stale audio before latency can grow without limit; mute continues sending encoded silence so the remote Opus stream remains stable. iOS calls integrate with CallKit for system incoming/outgoing presentation, lock-screen answer/end/mute actions and coordinated audio-session activation. The call screen shows the active audio route, can move audio between the speaker and the system-selected receiver or Bluetooth route, and retries the audio engine after transient interruptions. iOS can receive calls while its Reticulum connection is alive; waking a terminated or indefinitely suspended app still requires an operator-controlled PushKit service and is not claimed by this milestone.

Network diagnostics can be copied from the status panel without exposing private identity material. Each conversation also offers focused delivery diagnostics covering its announce, route, encrypted link, propagation node and outbox state. Automatic direct delivery remains the default, while individual contacts can prefer a propagation node with direct fallback when the node is unavailable; attachments continue to require an authenticated direct Resource link. Versioned JSON backups can be exported and restored after validation. Every save maintains a rolling copy of the previous valid snapshot; corrupt primary data is quarantined and recovered from that copy silently at launch. Unreferenced attachment files are cleaned conservatively in the background. Python-generated wire fixtures cover the Resource negotiation formats; live attachment interoperability with upstream Sideband remains an active validation target.

Native telemetry now supports the upstream LXMF `FIELD_TELEMETRY` format for timestamp, location, and battery sensors. Location is captured only after an explicit share action and only when sharing remains enabled for that contact. It is embedded in the encrypted LXMF message, persisted in backups, shown inline, included in transcript exports, and plotted as sent/received history with MapKit. Per-contact telemetry history can be removed without deleting the surrounding messages. `Scripts/verify-python-telemetry.py` generates the canonical fixture with upstream Python Sideband and checks byte-for-byte compatibility.

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

For the provisioned native macOS app, open `MacSideband.xcodeproj` and run the `SidebandMac` scheme. This target uses the same bundle identifier, Individual Apple team, synchronizable keychain identity and private CloudKit container as the iPhone/iPad target.

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

Private iCloud device sync is available under Network Status on both provisioned app targets. It merges conversations, messages and drafts, restores attachments from encrypted CloudKit assets, and coordinates queued-message ownership to avoid duplicate sends. Device-specific Reticulum route discoveries remain local.

TCP gateway connectivity works on physical iOS devices. iOS schedules background propagation refresh opportunistically and does not guarantee an indefinitely active TCP socket while the app is suspended. The iOS target is APNs-enabled and handles content-free silent wake hints by reconnecting and performing an encrypted LXMF propagation sync. Production wake hints still require an operator-controlled APNs provider that registers device tokens and sends `content-available` notifications; APNs timing is opportunistic, so propagation storage remains authoritative. Reticulum AutoInterface multicast on physical devices additionally requires Apple approval for the restricted multicast networking entitlement; the entitlement is intentionally not claimed by the current distribution profile.

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

The App Store Connect record is named `Lower Sideband`. Increment `CURRENT_PROJECT_VERSION` before every subsequent upload.

## Native dependency boundary

`Sideband-Upstream/`, `Reticulum-Upstream/` and `LXMF-Upstream/` are pinned reference snapshots. `TestConfig/*.py` and `Scripts/verify-python-telemetry.py` are developer-only interoperability tools. None are referenced by the Xcode targets or included in macOS/iOS bundles.

## Source snapshot

`Sideband-Upstream/` is a shallow checkout of upstream tag `1.9.8`, commit `8601d84580341f2c499041615d772610edb9eaab`. It is kept as a porting reference and retains its own Git history.

Protocol references are also pinned in `Reticulum-Upstream/` and `LXMF-Upstream/`; their individual licences apply.

## Licensing

The upstream application is licensed CC BY-NC-SA 4.0. This adaptation is provided under the same terms; see `LICENSE` and `NOTICE`.
