# Reticulum network map

Lower Sideband includes two distinct maps:

- the **Situation Map** presents geographic telemetry, trails and overlays;
- the **Network Map** presents the Reticulum topology observed by this device.

The Network Map follows the useful topology concepts exposed by MeshChatX's
Network Visualiser while remaining a clean native Swift implementation. It is
available from the main toolbar on macOS, iPhone and iPad.

## What the map shows

- the current Lower Sideband LXMF identity;
- active, connecting, stopped and recently observed network interfaces;
- validated destinations in the native Reticulum path table;
- next-hop transport identities for multi-hop paths;
- direct and multi-hop links;
- known conversations and discovered LXMF destinations without a current path;
- the selected LXMF propagation node.

This is an **observed topology**, not a complete view of the global Reticulum
network. Lower Sideband only draws links supported by its local interface and
path state. A destination with no current path is shown as unavailable and is
not attached to a fabricated route.

## Interaction

- Search by display name, destination hash, route or interface.
- Limit the visible graph by hop count or show every observed hop count.
- Include or hide unavailable historical destinations.
- Enable five-second automatic refresh or refresh manually.
- Pan, zoom and fit the topology.
- Select a destination to inspect its path, request a fresh path, copy/share
  its identity or open a conversation.
- Hover over nodes on macOS for a concise route summary.

Layout is deterministic, so nodes do not jump unnecessarily when the same
topology is refreshed. Labels use level-of-detail rules to remain usable on
large networks, while search and selection always reveal the relevant label.

## Privacy

The graph is generated locally from state Lower Sideband already holds. It is
not uploaded and does not query a central topology service. Sharing a
destination identity uses the system share sheet and remains an explicit user
action.

## Verification

`SidebandCoreTests` covers direct and multi-hop graph construction,
ancestor-preserving filtering and a deterministic 1,500-destination layout.
Mac and iOS builds compile the same graph models and shared SwiftUI view.
