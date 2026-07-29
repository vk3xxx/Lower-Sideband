# Changelog

## 1.3.55 (93)

- Consolidated the native Reticulum implementation into `ReticulumKit` as the
  sole packet, link, resource and interface transport layer.
- Added a complete I2P SAM v3 session plus STREAM CONNECT/ACCEPT lifecycle with
  HDLC framing, timeouts and pool-managed reconnects.
- Added RNodeMulti virtual-port selection, independent per-port configuration,
  state, flow control and simulator/protocol coverage.
- Added reference-compatible Backbone connector/listener behavior with
  independent peer sockets and authenticated discovery transport identities.

## 1.3.54 (92) - 2026-07-29

- Expanded searched multi-hop destinations into a complete hop-position view:
  local interface, known next-hop transport, unidentified relay positions and
  the requested destination.
- Clearly identify intermediate relay positions whose identities Reticulum
  intentionally does not expose, instead of fabricating a traceroute.
- Explicit searches now reveal matching distant, unavailable and individual
  destinations regardless of the normal map decluttering filters.

## 1.3.53 (91) - 2026-07-29

- Restored a genuinely full-window Network Map in the TestFlight iPhone/iPad
  build, including when the iPad app runs on Apple-silicon Macs.
- Kept the dedicated native macOS map window and its system full-screen support
  unchanged.

## 1.3.52 (90) - 2026-07-29

- Added a persistent Network Map control for hiding individual LXMF
  destinations, including their labels, hit targets and connecting lines.
- Kept interfaces, transports and propagation nodes visible so the underlying
  Reticulum network topology remains useful when destination visibility is off.

## 1.3.51 (89) - 2026-07-28

- Open the Reticulum network map in a dedicated resizable macOS window.
- Added native macOS full-screen support through the window control, an explicit
  toolbar action and the standard Control-Command-F shortcut.
- Kept the existing iPhone and iPad network-map presentation unchanged.

## 1.3.50 (88) - 2026-07-28

- Added an interactive Reticulum network map for macOS, iPhone and iPad.
- Visualised the local node, live interfaces, observed next-hop transports,
  direct destinations, multi-hop destinations and the selected LXMF
  propagation node without claiming unobserved global topology.
- Added search, hop filtering, unavailable-node visibility, automatic refresh,
  deterministic layout, pan/zoom, route details, path requests, contact sharing
  and direct conversation actions.
- Added graph correctness, filtering and 1,500-node layout regression coverage.

## 1.3.15 (53) - 2026-07-23

- Accept authenticated explicit Reticulum delivery proofs addressed to a secure link ID, preventing valid Linux LXMF proofs from timing out on Mac.
- Announce the local LXMF delivery identity before the first message on every new direct link and allow it to propagate before sending, preventing `SOURCE_UNKNOWN` on stock LXMF receivers.
- Added regression coverage for valid and forged explicit link proofs.

## 1.3.14 (52) - 2026-07-23

- Identify the local messaging identity on every Mac-initiated direct Reticulum link before sending LXMF payloads, allowing stock LXMF peers to validate the source and return delivery proofs.
- Reused one authenticated link-identification handshake for direct and propagation links and recorded it in persistent delivery diagnostics.

## 1.3.13 (51) - 2026-07-22

- Return direct-link LXMF delivery proofs over the same Reticulum interface that received the link, preventing multi-gateway proof loss.
- Added persistent identity, announce, inbound validation, interface and proof diagnostics to Network Status and copied reports.

## 1.3.12 (50) - 2026-07-22

- Made transient TCP tunnel-synthesis failures non-modal during automatic gateway recovery.
- Coalesced duplicate tunnel maintenance sends and exposed deferred attempts in Network Status diagnostics.

## 1.3.11 (49) - 2026-07-22

- Added an absolute UTC release gate so independent macOS and Linux soak runners begin the same run simultaneously.
- Isolated every Linux-to-Mac soak run by run ID and extended authenticated peer discovery to tolerate long public Reticulum paths.

## 1.3.10 (48) - 2026-07-22

- Made advisory link keepalive failures during automatic reconnects non-modal so background gateway handovers never interrupt messaging.
- Added a persistent deferred-keepalive diagnostic to Network Status while preserving genuine connection error reporting.

## 1.3.3 (41) - 2026-07-22

- Added an explicit **Announce Now** action to Network Status and Connection Settings on Mac, iPhone and iPad.
- Displayed the current LXMF destination and last successful announce time for internet-route testing and diagnostics.

## 1.3.2 (40) - 2026-07-21

- Rebuilt Settings around a native, searchable information architecture for connection, delivery, sync, privacy, notifications, voice, telemetry, radios, plugins, and advanced diagnostics.
- Added a dedicated macOS Settings window with a resizable sidebar and adaptive iPhone/iPad drill-down navigation.
- Added concise status summaries, contextual explanations, input validation, confirmations for destructive actions, and improved accessibility labels and help text.
- Simplified the iPhone conversation toolbar and made New Conversation an explicit, discoverable action with guided ID, contact-link, paste, and QR entry.
- Corrected the Reticulum announce emission-time wire format so gateways reliably replace stale paths after reconnecting or roaming.
- Removed stale per-interface routes when a TCP reticule disappears, retained redundant bootstrap gateways, and reject replayed older announces.
- Hardened proof-timeout recovery with route refreshes and made interrupted encrypted attachment resources return safely to the durable outbox.
- Added isolated bidirectional endurance testing with random send jitter, forced reconnects, route recovery, and byte-for-byte attachment integrity verification.
- Added bounded per-destination delivery windows, single-flight outbox draining, disconnect requeueing, and stale secure-link retirement to prevent burst traffic from duplicating or stranding messages.
- Delayed resource proofs until LXMF payload validation and durable storage complete, made repeated advertisements idempotent, and serialised attachments per conversation.
- Corrected continuation requests for partial 82-hash resource-map windows so attachments larger than 65 KB complete reliably.
- Added signed attachment timestamps so text and resource messages retain their original chronological order across devices.
- Validated 2,000 randomized bidirectional messages and ten binary attachments between macOS and iPad Simulator with zero loss, duplicates, ordering errors, integrity errors, failures, or delivery timeouts on a stable gateway path.

## 1.3.1 (39) - 2026-07-21

- Added content-free CloudKit silent-push subscriptions for encrypted cross-device background synchronisation.
- Added read-only native migration of historical Python Sideband SQLite conversations and messages.
- Added verified chunked RNode firmware flashing, a macOS vendor-bootloader adapter and physical acceptance hooks.
- Added a native macOS Reticulum PipeInterface and hardened runtime memory, low-power and thermal diagnostics.
- Added dual-stack gateway health checks and proof-based Mac/iOS delivery soak automation for automatic, local and public network modes.

## 1.3.0 (38) - 2026-07-21

- Embedded reproducible official Codec2 1.2.0 builds for iPhone, iPad, Simulator, and universal macOS.
- Added native 700C–3200 bit/s Codec2 voice-message encoding and playback.
- Added native Codec2 LXST live-call capture, framing, jitter buffering, and playback.
- Added user-selectable Opus and low-bandwidth Codec2 voice profiles.
- Completed and documented the seven-area native feature-parity pass.

## 1.2.9 (37) - 2026-07-21

- Added signed RNode firmware catalog verification and HTTPS/digest-verified downloads.
- Added a platform flasher contract plus portable RNode configuration import/export.
- Added safe native Micron and BBCode presentation alongside Markdown.
- Kept unknown rich-text tags visible and trust-gated all non-plain rendering.

## 1.2.8 (36) - 2026-07-21

- Added an importable, declarative plugin format that cannot execute downloaded code.
- Added strict schema, size, permission, command and template validation.
- Added permission-redacted response templates and runtime plugin registration.
- Preserved per-contact authorization, timeouts, enable controls and audit records.

## 1.2.7 (35) - 2026-07-21

- Added native UDP and macOS TCP Server Reticulum interfaces with HDLC and IFAC support.
- Added shared-instance connection configuration.
- Added validated I2P SAM command/reply support.
- Added upstream-compatible Weave WDCL framing and endpoint commands.

## 1.2.6 (34) - 2026-07-21

- Added typed upstream-compatible motion, environmental and magnetic telemetry.
- Added scheduled telemetry policies, exclusions, propagation-only preference and safe MQTT record export.
- Added validated offline tile-package manifests and situation trails.
- Added elevation-angle calculations alongside distance, bearing and shared radio horizon.

## 1.2.5 (33) - 2026-07-21

- Added authenticated, passphrase-encrypted complete profile archives.
- Added portable Base32 private identity export/import.
- Added direct import of Python Reticulum `primary_identity` files.
- Profile restore validates data before atomically replacing the active identity and application snapshot.

## 1.2.4 (32) - 2026-07-21

- Added native LXMF proof-of-work stamp generation and validation.
- Added trusted-peer delivery ticket stamps and expiry metadata.
- Added rotating Reticulum destination ratchets, retained-key decryption and ratchet-bearing announces.
- Corrected signed message validation for stamped LXMF payloads.

Notable changes to Lower Sideband are documented here. Builds remain development/TestFlight builds unless explicitly designated as release candidates.

## [1.2.3] - 2026-07-21

### Documentation and repository quality

- Reorganised project documentation around focused build, architecture, networking, RNode, testing, roadmap, security, and contribution guides.
- Corrected stale dependency and feature-parity statements.
- Added structured GitHub issue forms and a pull-request template.
- Added a repository consistency check and hardened the manual-only GitHub Actions workflow.
- Ignored accidental numbered Xcode project copies while retaining `MacSideband.xcodeproj` as the generated canonical project.

## [1.2.2] - 2026-07-21

- Added native macOS Reticulum Transport Instance mode with validated route learning, interface-mode boundaries, reverse routes, link routes, header rewriting, and packet-loop suppression.

## [1.2.1] - 2026-07-21

- Completed native RNode beacon, framebuffer, ROM, firmware-validation, diagnostic, and simulator support.

## [1.2.0] - 2026-07-21

- Added Python-compatible low-bandwidth LXMF voice messages.

## [1.1.9] - 2026-07-21

- Added generic serial/KISS interfaces, IFAC configuration, and Reticulum interface modes.

## [1.1.8] - 2026-07-21

- Expanded permission-scoped native command, service, and telemetry plugins.

## [1.1.7] - 2026-07-21

- Added a unified online/offline situation map.

## [1.1.6] - 2026-07-21

- Completed native telemetry collection, requests, history, export, and upstream-compatible encoding.

Earlier development history is available in the repository commit log and the two archived improvement ledgers under [`docs/`](docs/).
