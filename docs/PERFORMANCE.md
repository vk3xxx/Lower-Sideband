# Performance and resource budgets

Lower Sideband keeps Reticulum packet processing lossless while deliberately
coalescing presentation updates. The packet parser, route table and LXMF engine
still receive every packet; only observable counters and discovery-list
snapshots are published at bounded intervals.

## Runtime design

- Packet totals are published at most once per second.
- Repeated announces are merged and the discovery snapshot is published at
  most once per second. Protocol work that needs a fresh announce
  flushes the pending snapshot first.
- Display names and LXST destination classification are computed when an
  announce is accepted, not during SwiftUI rendering.
- Discovery observation lives in a dedicated sidebar view. The idle list is
  limited to 120 destinations and search results to 240 unless the user asks
  to show all.
- Relative timestamps update once per minute instead of running a timer in
  every row.
- Network-map snapshots are cached briefly and remain bounded by the existing
  map limits.
- Public automatic discovery keeps the three highest-priority gateways active.
  Remaining gateways are ordered standby candidates and replace failed active
  sockets without restarting healthy routes.
- Inline image thumbnails use an `NSCache` capped at 48 images and 64 MiB, so
  macOS can evict them immediately under memory pressure.

## Mac acceptance budgets

Measure a Release build after a two-minute warm-up while it is connected to a
busy public Reticulum network.

| Scenario | CPU target | Resident-memory target |
| --- | ---: | ---: |
| Idle, no visible map | 3% average, no sustained core saturation | 192 MiB or less |
| Active discovery traffic | 12% average | no continuing growth after five minutes |
| Scrolling 120 discovery rows | responsive at the display refresh rate | no continuing growth |

Additional pass conditions:

- no more than three automatic public gateway interfaces are active (system
  HTTP connection pooling and CloudKit may use additional operating-system
  sockets);
- packet and announce totals continue increasing under load;
- queued LXMF messages and delivery proofs are not delayed by UI batching;
- memory returns toward its previous level after leaving an image-heavy chat;
- the selected conversation does not redraw for every background announce.

Use `Scripts/check-mac-performance.sh <pid> [seconds]` to collect an auditable
CSV sample and summary for a running Release build.
