# Migrating from Python Sideband

## Migration & Restore centre

After selecting a historical `sideband.db`, Lower Sideband validates the file
read-only and opens a migration centre. You can:

- choose individual conversations;
- include or exclude message history, telemetry and announces;
- safely merge with existing conversations or import only destinations that
  are not already present; and
- review source size and supported tables before committing the import.

The app creates an encrypted rollback snapshot before applying the migration.
**Undo Last Python Import** remains available after relaunch until it is used
or superseded by a later import. The source SQLite file is never modified.

Lower Sideband can inspect and merge a historical Python Sideband
`sideband.db` without Python and without modifying the source database.

## Import workflow

1. In **Settings > Data**, choose **Import Python Sideband Database**.
2. Select the original `sideband.db`.
3. Review the preflight summary. Lower Sideband reports the source size and the
   number of conversations, messages, telemetry records, and announces before
   making any changes.
4. Choose **Import** to merge the validated records with existing Lower
   Sideband data.
5. Use **Undo Last Python Import** if the result is not what you expected.
   Rollback remains available until the app closes or another import begins.

Create a normal encrypted Lower Sideband backup after reviewing a successful
import. That backup is the durable rollback point across later launches.

## Data coverage

The importer understands the current historical Python tables:

| Python table | Native result |
| --- | --- |
| `conv` | Conversation name, trust, exact unread count, pin/archive/block/mute state, notification preview choice, notes, tags, telemetry/request preferences, propagation preference, and supported appearance metadata |
| `lxm` | Incoming and outgoing messages, timestamps, delivery state, LXMF identifiers, renderer, replies, reactions, comments, continuations, telemetry, telemetry streams, voice fields, and safe native commands |
| `telemetry` | Valid telemetry readings attached to timestamped imported messages |
| `announce` | LXMF delivery discoveries, marked unverified until observed and cryptographically validated again |

Malformed, unsupported, or unmatched rows are skipped and counted in the
completion report. Binary message bodies that cannot be represented as text
are retained as an explicit legacy-binary placeholder rather than interpreted
unsafely.

The importer recognises the canonical Python column names and known historical
aliases used by older Sideband databases. This includes binary and hexadecimal
text forms of destination and message hashes. A compatibility fixture protects
these older layouts from regression.

## Safety and limitations

- The source SQLite database is opened read-only. Automated tests verify its
  bytes are unchanged after preview and import.
- Import is a merge. Existing conversations are preserved and matching
  destinations are reconciled through the normal snapshot merge rules.
- Python identities, private keys, network configuration, and executable
  plugins are not silently imported. Use the dedicated encrypted identity
  migration flow and review trust fingerprints separately.
- Historical announces are never treated as verified identity evidence.
- Local attachment paths from another platform are not trusted or copied
  automatically.
- The importer has bounded row and blob handling. It does not execute SQL,
  Python, plugin code, or content from the database.

Keep the original database and a Lower Sideband encrypted backup until you
have verified conversation names, recent messages, telemetry, and contact
identity fingerprints.
