# 100 App Improvements — 18 July 2026

This ledger records the 100-point improvement pass completed for the native Swift macOS and iOS applications. The numbered entries are grouped by area and correspond to the implementation and verification commits made during the pass.

## Native plugins

1. Validate plugin manifests before registration.
2. Reject duplicate plugin identifiers and command conflicts.
3. Keep plugin registry ordering deterministic.
4. Require explicit per-contact plugin authorization.
5. Require trusted, verified contacts before remote plugin execution.
6. Provide plugins only the context permissions declared in their manifest.
7. Redact undeclared or sensitive context from plugin requests.
8. Enforce a bounded execution timeout for native plugins.
9. Return structured success, rejection, timeout, and failure outcomes.
10. Persist privacy-safe encrypted plugin audit events and expose them in diagnostics.

## Telemetry

11. Validate coordinates, altitude, accuracy, speed, heading, battery, and timestamps.
12. Classify telemetry samples as current or stale.
13. Retain bounded telemetry history per conversation.
14. Summarize tracks with start, end, sample count, and freshness.
15. Calculate travelled distance from recorded samples.
16. Calculate track duration from sample timestamps.
17. Draw recorded tracks as map polylines.
18. Export interoperable telemetry CSV files.
19. Export interoperable GPX track files.
20. Surface clear current, stale, and unavailable telemetry states in the UI.

## Contact appearance and metadata

21. Add encrypted private contact notes.
22. Add a selectable contact symbol.
23. Add a selectable contact colour.
24. Persist contact appearance metadata in encrypted snapshots.
25. Merge contact appearance safely through CloudKit.
26. Include appearance metadata in contact collections.
27. Export contact appearance without exporting local secrets.
28. Import contact appearance without granting trust or verification.
29. Decode legacy contacts safely when appearance fields are absent.
30. Add native macOS and iOS controls for editing contact appearance.

## Delivery resilience and diagnostics

31. Persist the delivery-attempt count for each outgoing message.
32. Persist the most recent delivery-attempt timestamp.
33. Persist the most recent delivery mode.
34. Persist a bounded, user-safe delivery failure reason.
35. Record direct, opportunistic, resource, and propagation attempts accurately.
36. Preserve proof-timeout evidence instead of silently resetting it.
37. Clean up completed or invalid delivery receipts.
38. Preserve the newest delivery evidence during CloudKit merges.
39. Explain queued and failed states with actionable diagnostics.
40. Add regression tests for legacy decoding and delivery-state merging.

## iOS lifecycle and background recovery

41. Report whether a background refresh actually completed useful work.
42. Bound background refresh execution to 25 seconds.
43. Persist the last background refresh time.
44. Persist the last background refresh result.
45. Allow a bounded network-recovery window before giving up.
46. Refresh the local announce during background maintenance.
47. Synchronize with the configured propagation node in the background.
48. Flush queued messages after network recovery.
49. Flush queued messages when the app becomes active.
50. Surface background recovery state in diagnostics.

## Conversation organization and search

51. Add all, unread, pinned, archived, muted, and failed conversation filters.
52. Add recent-activity, alphabetical, and unread-first sorting.
53. Search private contact notes as well as display names and destinations.
54. Search message bodies, quoted text, and attachment filenames.
55. Add a bulk “mark all read” action.
56. Add a bulk action to archive read, unpinned conversations.
57. Add a bulk “unarchive all” action.
58. Recover selection safely when filtering hides the selected conversation.
59. Prevent discovery-only rows from leaking into incompatible filters.
60. Add clear result counts, empty states, and organization regression tests.

## Attachments and media

61. Sanitize imported attachment filenames.
62. Normalize and infer MIME types consistently.
63. Confine untrusted relative paths to the attachment store.
64. Audit local attachment hashes and mark missing or corrupt data failed.
65. Return whether an attachment send was accepted into the outbox.
66. Restore a failed attachment send to the conversation draft.
67. Restore file selections after transient send failure.
68. Clean up payload files when an attachment or message is discarded.
69. Clean up staged selections when the composer disappears.
70. Add accessible transfer progress and attachment recovery tests.

## Accessibility and keyboard workflow

71. Add a keyboard shortcut for starting a conversation.
72. Add a keyboard shortcut for searching conversations.
73. Add a keyboard shortcut for focusing the message composer.
74. Send with Command-Return while retaining multiline editing.
75. Focus the composer automatically when a conversation opens.
76. Make destination entry predictable for keyboard-only users.
77. Add stable accessibility identifiers to important controls.
78. Add accessible transfer progress labels and values.
79. Group conversation rows into coherent accessibility elements.
80. Mark primary and cancellation actions with the correct semantics.

## Persistence and CloudKit

81. Hash snapshots and skip unchanged encryption and disk writes.
82. Preserve rolling backups while suppressing redundant writes.
83. Bound the in-memory transcript cache to 64 conversations.
84. Reject snapshot payloads larger than 256 MiB before decoding.
85. Bound conversation, message, discovery, draft, and voice-call collections.
86. Validate persisted message length and delivery metadata.
87. Validate attachment count, size, path, progress, name, and content hash.
88. Skip unchanged CloudKit attachment uploads during a sync session.
89. Prune the CloudKit upload cache when attachments are removed.
90. Apply merged voice-call history during cross-device CloudKit sync.

## Repository quality and verification

91. Keep GitHub Actions opt-in with `workflow_dispatch` only.
92. Correct the manual CI device build to use the `SidebandIOS` scheme.
93. Audit the application targets to confirm there is no Python runtime dependency.
94. Audit Swift Package Manager to confirm there are no third-party package dependencies.
95. Scan tracked source and configuration for common private-key and token signatures.
96. Scan tracked files for accidentally committed large binaries.
97. Expand and pass the native Swift regression suite at 179 tests.
98. Complete a clean unsigned macOS application build.
99. Complete a clean unsigned iOS Simulator application build.
100. Add this versioned improvement ledger so future work can be reviewed against shipped behaviour.

## Verification summary

- Swift tests: 179 passed.
- macOS Debug build: passed.
- iOS Simulator Debug build: passed.
- Runtime dependencies: Apple frameworks and the repository's native Swift targets only.
- CI behavior: manual dispatch only; commits do not start GitHub builds.
