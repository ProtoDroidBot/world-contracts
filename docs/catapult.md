# Smart Catapult routes

The `world_catapult::catapult` module adds a deterministic one-way route sidecar to an existing Slingshot/Smart Catapult `gate::Gate`. It selects a destination solar system directly and does not require a second Gate at the destination.

See [Package topology and deployment identity](package-topology.md) for the split-package address model and upgrade rules.

## Route state and authorization

`CatapultKey { gate_id }` derives one shared `Catapult` object from the configured feature registry. The sidecar records the source Gate, source and destination solar systems, exact distance, revision, and update time.

Creation and route changes require an authorized sponsor through `AdminACL`. The source Gate must be offline, unpaired, and a configured catapult type. The destination must be distinct and within the type's `GateConfig` maximum distance. Route updates use an expected revision; a zero destination clears the route.

Jump authorization requires the source Gate online and its stored route current. A successful one-way use emits `CatapultJumpEvent`; the contract never creates or looks up a far-side Gate.

## Deployment and testing

This module is published from `contracts/world_catapult` and depends on the base `world` package. Use the `catapult` capability package for calls, its type origin for derived keys/types, and its registry ID for the shared registry. A fresh split deployment writes the complete record to `world-features.v1.json`; an upgrade changes only the call package.

Run its Move tests in the efctl Sui environment:

```sh
sui move test --path contracts/world_catapult
```

Deployment verification must also confirm the live call package exposes `catapult` and that the shared registry's exact type is `<catapultTypeOrigin>::catapult::CatapultRegistry`.
