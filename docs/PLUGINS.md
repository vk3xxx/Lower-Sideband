# Native plugin model

Lower Sideband plugins are native Swift components bundled with the app or
bounded declarative JSON definitions. They cannot download or execute code,
launch processes, read files, or make network requests. This keeps plugin
behaviour deterministic, reviewable, and suitable for the Apple sandbox.

## Capabilities

Command plugins can declare only the context they need:

| Permission | Available context |
| --- | --- |
| `networkStatus` | Ready/offline state, route availability, hop count, and the active ReticulumKit interface identifier |
| `conversationMetadata` | Destination hash and local conversation display name |
| `messageMetadata` | Incoming/outgoing direction and message timestamp; never message content |
| `telemetryRead` | Bounded display-safe sensor summaries; never raw coordinates |
| `telemetryWrite` | Canonical MessagePack telemetry contributed by an app-bundled provider |
| `serviceLifecycle` | Start, stop, and status for an app-bundled service |

Undeclared values are removed before the plugin is called. Remote plugin
commands additionally require the contact to be trusted, fingerprint-verified,
explicitly authorised, and enabled for plugin requests.

## Structured responses

Native and schema-version-2 declarative plugins may return:

- plain text;
- a status presentation; or
- a metric-list presentation with up to 12 bounded key/value rows.

Structured responses always include a portable text fallback for recipients
that do not render plugin cards. Declarative templates support route, contact,
message metadata, telemetry summary, and bounded argument tokens. Unknown
tokens and unsafe capabilities are rejected during import.

Schema-version-1 declarative plugins remain supported.

## Operations and privacy

Each plugin has bounded execution time. The app records invocation count, last
outcome, and a privacy-safe audit event, but never stores command arguments,
message text, telemetry values, or sender details in the plugin audit log.
