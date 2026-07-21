# Changelog

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
