# Lower Sideband operations

The apps prefer explicit configuration, then local Bonjour/AutoInterface/RNode
connections, then the health-ranked public gateway pool. Production deployments
should operate at least two gateways and two LXMF propagation nodes in separate
failure domains, expose IPv6 and IPv4, and alert on TCP reachability, announce
age, path count, propagation queue age, disk space and clock drift.

`Scripts/verify-gateways.sh` performs a read-only endpoint check from
`Infrastructure/gateways.txt`. `Scripts/run-delivery-soak.sh` builds the Mac and
iOS simulator apps and requires delivery proofs for numbered messages in both
directions. Run it in `automatic`, `local`, and `public` modes after adding real
addresses. This tooling does not alter DNS.

`Scripts/certify-public-internet.sh` converts multiple completed, independent
Internet-only soak reports into a hashed production-acceptance certificate. It
requires at least 2,500 proved messages in each direction on every route,
verified file/image payloads, reconnect coverage, correct ordering, and zero
timeouts, failures, gaps, or duplicates.

No third-party public gateway is represented as carrier-grade. Operators must
monitor their own service and publish maintenance/contact information.
