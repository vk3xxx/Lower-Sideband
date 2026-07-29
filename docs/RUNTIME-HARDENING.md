# Runtime and lifecycle hardening

Lower Sideband treats foreground transitions, background wakes, network changes,
thermal pressure and memory pressure as normal operating conditions.

## Behaviour

- Foregrounding re-evaluates every ReticulumKit interface, recovers unproved
  outbound messages, reconnects, synchronises propagation and flushes queues.
- Backgrounding durably flushes pending state, removes temporary plaintext,
  releases rebuildable indexes and schedules the next bounded refresh.
- Silent wakes are coalesced, cancellation-aware and time-bounded.
- Low Power Mode or serious thermal pressure lengthens periodic maintenance
  without delaying explicit user sends or queued-delivery recovery.
- Operating-system memory warnings release caches while preserving encrypted
  messages and attachments.

## Measured health

Settings reports network transitions, memory warnings, foreground runtime,
background-wake success rate and whether the app is conserving energy. These
counters persist across launches and are included in privacy-safe diagnostics.

On iOS, MetricKit delivery is registered during startup. Lower Sideband records
only aggregate metric and diagnostic payload counts and their latest arrival
time; payload contents remain in Apple's MetricKit pipeline and are never
combined with conversation data. The production quality gate runs tests
serially before Release builds, avoiding false timing failures caused by
hundreds of unrelated tests competing concurrently.

Production acceptance should include:

1. repeated Wi-Fi/cellular/IPv6/IPv4 transitions;
2. foreground/background and device-lock cycles;
3. Low Power Mode and simulated memory warnings;
4. a 24-hour Instruments run checking allocations, wakeups and energy;
5. queued text, image, file, voice and propagation delivery throughout.

No acceptance run may claim guaranteed delivery merely because a packet was
queued; a Reticulum/LXMF delivery proof or verified inbound record is required.
