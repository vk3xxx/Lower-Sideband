# Changelog

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
