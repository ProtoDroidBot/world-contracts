# Assembly access

The `world_assembly_access::assembly_access` module provides on-chain access policy and grant objects for completed smart assemblies. Portable and field assemblies remain governed by EveJS's durable local policy; a local smart-assembly grant is not usable until its chain object and complete delegation ancestry have been verified.

See [Package topology and deployment identity](package-topology.md) for the split-package address model and upgrade rules.

## Objects and capabilities

The package creates one shared `AssemblyAccessRegistry`, derives one shared policy per assembly, and derives grants from the policy plus a caller-supplied operation UUID. The initial capability vocabulary is:

- `gui.view`;
- `operate`;
- `inventory.deposit`;
- `inventory.withdraw`;
- `configure`; and
- `manage_access`.

Owner issuance proves the assembly's exact `OwnerCap`. A delegated grant must be a capability subset, cannot outlive its parent, and must reduce the remaining delegation depth. Revocation or expiry of any ancestor invalidates its descendants. Player grants bind to a Character; NPC grants bind to a current, non-retired `NpcProfile` from the configured NPC package and registry.

## Cross-owner custody

Access does not itself change game ownership. The custody entry points separately validate direct, unexpired deposit/withdraw capabilities and move Storage Unit inventory on chain. A storage-to-storage transaction checks both policies atomically. Successful operations emit `AssemblyCustodyTransferred`, bound to the operation UUID, actor, source, destination, type, and quantity.

EveJS verifies that finalized event before committing the game item owner/location mutation. Custody capabilities are owner-issued and non-delegable; GUI visibility and ordinary operation never imply withdrawal authority.

## Deployment and testing

This module is published from `contracts/world_assembly_access`. It depends on both the base `world` package and `world_npc`. Use `accessPackageId` for calls, `accessTypeOrigin` for derived keys/types, and `accessRegistryId` for the shared registry. A fresh split deployment writes all three to the combined `npc-deployment.json` manifest; an upgrade changes only the call package.

Run its Move tests in the efctl Sui environment:

```sh
sui move test --path contracts/world_assembly_access
```

Deployment verification must also confirm the live call package exposes `assembly_access` and that the shared registry's exact type is `<accessTypeOrigin>::assembly_access::AssemblyAccessRegistry`.
