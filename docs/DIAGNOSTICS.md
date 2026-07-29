# Diagnostics and support reports

Lower Sideband exposes live service health in **Settings → Advanced**. The
screen combines connection state, routing and delivery counters, gateway
history, background wake health, MetricKit receipt counts, radio state and
attachment-storage integrity.

**Export Redacted Support Report** creates a versioned JSON report suitable for
sharing with a developer. The export contains aggregate health counts and
technical state, but does not contain:

- message or attachment content;
- private keys or public identity values;
- exact IPv4 or IPv6 addresses;
- hostnames or local filesystem paths; or
- the user's configured display name.

Repeated identifiers are replaced by report-local stable tokens. This permits
correlation within one report without revealing the original value.

The older **Copy Diagnostics** action remains available for local
troubleshooting and can contain exact endpoint context. Review that text before
sharing it. Prefer the redacted export for support requests.
