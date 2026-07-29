# Managed connectivity infrastructure

Lower Sideband can consume an operator-managed, cryptographically signed
infrastructure manifest. This is optional: automatic LAN discovery and the
community public-gateway pool continue to work without it.

## What it provides

- two to sixteen ordered TCP/Backbone gateway entry points;
- redundant IPv6 and IPv4 endpoints with the app's existing health scoring,
  cooldown, failover and reconnection;
- preferred LXMF propagation nodes for store-and-forward delivery;
- an optional HTTPS endpoint for privacy-preserving APNs wake registration.

The user-configured gateway remains first priority. Verified managed gateways
are considered next, followed by the public community directory and built-in
fallbacks. Lower Sideband never changes system DNS.

## Trust model

The manifest is signed by a 64-byte Reticulum identity public key configured in
the app. HTTPS protects transport privacy, but the Reticulum identity signature
is authoritative. A compromised DNS resolver, CDN or web server therefore
cannot replace gateway or wake-service details without the operator's signing
identity.

Manifests:

- use schema version `1`;
- expire and may be valid for no more than 31 days;
- must contain at least two distinct gateways;
- are limited to 64 KiB, 16 gateways and 16 propagation nodes;
- require HTTPS for the directory and wake service;
- reject invalid, expired, redirected or incorrectly signed content.

Canonical JSON is encoded with ISO-8601 dates and sorted keys. The `signature`
is the lowercase hexadecimal Reticulum Ed25519 signature of the canonical
`manifest` object.

## Example

```json
{
  "manifest": {
    "schemaVersion": 1,
    "issuedAt": "2026-07-29T00:00:00Z",
    "expiresAt": "2026-08-05T00:00:00Z",
    "gateways": [
      {"name":"Primary IPv6","host":"gateway6.example.net","port":4242,"priority":10},
      {"name":"Secondary IPv4","host":"gateway4.example.net","port":4242,"priority":20}
    ],
    "propagationNodes": [
      {"name":"Primary store and forward","destinationHash":"0123456789abcdef0123456789abcdef","priority":10}
    ],
    "wakeRegistrationURL":"https://wake.example.net/v1/devices"
  },
  "signature":"<128 lowercase hexadecimal characters>"
}
```

Generate and sign the object with
`ManagedInfrastructureDirectory.signedEnvelope(manifest:identity:)`. Keep the
operator private identity offline or in a managed signing service; applications
receive only its public key.

## Background wakes

When explicitly enabled, the app sends the verified wake service:

- APNs device token and sandbox/production environment;
- LXMF delivery destination and public identity;
- timestamp and one-time nonce;
- an identity signature over those fields.

It never sends message text, attachments or private keys. The service should
authenticate this signature, retain only the latest token per delivery
destination, use collapse IDs and silent notifications, rate-limit wake
requests, and delete stale APNs tokens. APNs only wakes the client; encrypted
messages remain exclusively on Reticulum/LXMF.

Lower Sideband automatically re-registers rotated APNs tokens, binds every
registration destination to the signing Reticulum identity, refreshes a valid
registration at most once per day, coalesces simultaneous wakes, and treats a
cold-launch deferred wake as accepted instead of incorrectly reporting a
background failure to iOS. Only silent pushes with `aps.content-available = 1`
start the bounded propagation/cloud/outbox synchronisation.

## Deployment checklist

1. Deploy at least two independently hosted Reticulum TCP/Backbone gateways,
   with IPv6 and IPv4 reachability.
2. Deploy and monitor at least two LXMF propagation nodes.
3. Create the offline Reticulum manifest-signing identity.
4. Publish the signed manifest over HTTPS and rotate it before expiry.
5. Optionally deploy the APNs provider using an Apple APNs signing key.
6. Configure the signed-directory URL and operator public key in Lower
   Sideband, verify it, and run the upstream interoperability matrix.

Server hosting, domain ownership, monitoring and Apple APNs credentials are
operator inputs and are intentionally not embedded in the application.
