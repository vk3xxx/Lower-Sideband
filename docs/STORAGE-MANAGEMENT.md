# Storage and performance management

Lower Sideband stores messages and attachments locally in encrypted form. The
Storage Management section in Settings gives the user explicit control without
turning routine cleanup into a delivery risk.

## Safe defaults

- Automatic maintenance is off by default.
- Messages and attachments are retained forever by default.
- Attachment storage has no quota by default.
- Starred content is always retained.
- Queued and scheduled messages are always retained.
- Attachments that are queued or transferring are always retained.

## Retention and quotas

Message retention removes the oldest completed or failed, unstarred messages.
Attachment retention removes only eligible attachment payloads while leaving
the message in the transcript. The attachment quota is applied oldest-first
after retention rules. Maintenance also removes encrypted files that are no
longer referenced by the message database.

Users can preview current encrypted storage usage, run maintenance manually,
or enable automatic maintenance at launch. The most recent cleanup summary is
persisted for transparency.

## Performance controls

“Release Temporary Caches” discards only rebuildable transcript and index
caches. It never changes encrypted durable content. The same cache release is
used in response to operating-system memory pressure.

## Verification

Automated tests confirm limit normalization and ensure maintenance preserves
starred messages, queued work and active attachment transfers. Release
validation exercises both macOS and iOS builds.
