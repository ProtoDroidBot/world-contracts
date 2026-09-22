# Action contracts

The action-contract layer separates portable intent and orchestration state from the authoritative game simulation. Contracts authenticate who may request work, bind requests to exact payloads and expected revisions, and record lifecycle receipts. A game server or keeper still revalidates and executes real inventory, production, infrastructure, and delayed automation effects.

## Common queue

`world_action_queue::action_queue` defines the common `Action` lifecycle: queued, claimed, fulfilled, failed, or cancelled. It also carries expiry, exact priority values, non-conflicting bit flags, payload commitments, bounded outcomes, claim leases, and monotonically increasing revisions. Completion stores an internally calculated outcome commitment and emits an `ActionReceipt` with the terminal revision and completion time.

The package initializer creates one `ActionQueueRegistry`. Each assembly then receives a deterministic `AssemblyActionQueue` derived from `AssemblyQueueKey { assembly_id }`. Actions are derived below that queue root by their 16-byte action ID. The registry is therefore touched only when a queue root is first created; unrelated assemblies do not contend on a global shared object while submitting or processing actions. EveJS reconciliation initializes missing roots in batches through the authorized server path. Owners may also initialize their own root with `create_queue`.

Generic JSON actions store a caller-calculated SHA-256 commitment that clients and the server verify before interpreting the payload. Typed action packages calculate the same SHA-256 commitment inside Move over the exact BCS command bytes, preventing a caller from pairing a command with an unrelated digest while keeping one verification algorithm across the unified journal.

## Typed action groups

| Package | Purpose | Important constraints |
| --- | --- | --- |
| `world_industry_actions` | Start, discontinue, select blueprint, empty, and lane-aware production/transfer commands | Validates the mirrored Smart Industry revision, production state, lane, blueprint, target, direction, and quantity before enqueueing. |
| `world_logistics_actions` | Portable transfer intents for storage, Industry input/output, turrets, Network Node fuel, ships, field storage, and future assembly endpoints | Binds expected source and destination inventory revisions. Uses prepare/claim followed by settle or fail; settlement records actual quantity and both resulting revisions. |
| `world_infrastructure_actions` | Assembly state, energy connect/disconnect, gate link/unlink, refuel, and dormant-gate reactivation | Uses typed revision-bound commands. Owner requests and authorized server/NPC requests share the same queue lifecycle. |
| `world_automation` | Bounded sequences of other actions | Supports up to 32 steps, prior-step dependencies, deadlines, retry delay/attempt limits, and signal predicates. Activation, pause, resume, cancellation, advancement, and step results are explicit. |

Logistics intentionally identifies endpoint kind separately from endpoint ID. Transfer intent portability does not depend on a single assembly implementation, while contracts still reject unsupported endpoint kinds and same-endpoint transfers. The two-phase lifecycle is an authorization and audit boundary, not escrow: the authoritative inventory service must re-read custody and both revisions immediately before mutation.

## Automation execution

Sui does not wake a transaction when a delay expires. `world_automation` stores eligible timing and dependency state, but an authorized server or keeper must call `advance`, queue the selected common action, and later record the result. Retry policy changes eligibility; it never autonomously retries an external effect.

Signal predicates are bounded and deterministic (`none`, `exists`, byte equality, or unsigned greater-than-or-equal). A keeper supplies the observed signal key/value when advancing and remains responsible for proving that observation against the appropriate on-chain or authoritative-world source.

## Deployment

Fresh deployment publishes in dependency order: common queue, Industry Actions, Logistics Actions, Infrastructure Actions, then Automation. Their call-package, stable type-origin, and registry IDs are recorded as independent capabilities in `deployments/<network>/world-features.v1.json`, synchronized into EveJS, and exposed to Smart Assembly Control. Historical flat schemas retain compatibility fallbacks during migration but do not select the dedicated group-3 through group-5 packages.

Package-local Move tests cover creation, typed validation, claims, settlement/receipts, and keeper progression. Run them with the Sui CLI in the efctl environment; see [Package topology and deployment identity](package-topology.md) for focused commands.
