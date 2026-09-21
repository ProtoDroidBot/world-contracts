# Transponder commitments

`world_transponder::transponder` lets a tribe or NPC faction author a stable on-chain commitment to a private transponder code. It follows the same privacy boundary as an unrevealed smart-assembly location: the chain stores a 32-byte digest, not the private value.

See [Package topology and deployment identity](package-topology.md) for the split-package address model and upgrade rules.

Sui state and transaction inputs are public. A plaintext code, password, salt, encryption key, or private sharing list must never be passed to a Move call. The code and its 32-byte random salt are distributed to trusted members through an off-chain encrypted channel. Members fetch the commitment and reproduce the digest locally.

## Commitment protocol

The current hash scheme is `1`, meaning BLAKE2b-256 over the BCS serialization of these fields in order:

1. `domain: vector<u8>` — UTF-8 `EVE_FRONTIER_TRANSPONDER_COMMITMENT_V1`;
2. `registry_id: address` — the world's ObjectRegistry ID;
3. `tenant: String`;
4. `scope_kind: u8` — `1` for tribe or `2` for faction;
5. `scope_id: String` — the canonical decimal tribe ID or canonical faction key;
6. `revision: u64` — `1` for creation and the record's next revision for rotation;
7. `code: String` — the trimmed 1–32 character transponder code;
8. `salt: vector<u8>` — exactly 32 cryptographically random bytes.

Binding the digest to the registry, tenant, scope and revision prevents copying a valid commitment into another world, group or historical revision. A salt is part of the private shared bundle. Publishing it weakens short codes to an offline guessing attack; a public salt only prevents precomputation.

There is deliberately no on-chain verification function. Supplying the code and salt to such a function would disclose them in the transaction, even if the Move function returned only a boolean.

## Identity and authorization

Each record is derived under the ObjectRegistry with `TransponderScopeKey { tenant, scope_kind, scope_id }`. This produces at most one stable record per tenant and tribe/faction. Readers can calculate the ID before creation using the module's type-origin package.

- `author_for_tribe` requires a Character from the same registry and the transaction sender must equal its `character_address`.
- `author_for_faction` requires a non-retired `NpcProfile` from the same registry and the sender must be its permanent faction wallet.
- The creator becomes the record authority. Membership alone cannot overwrite it.
- Rotations and revocations recheck the authority, current scope membership, and expected revision.
- `transfer_tribe_authority` requires the current authority plus another Character in the same registry/tenant/tribe. Transfer revokes and clears the old commitment; the successor must rotate a fresh commitment.
- NPC faction authority does not transfer through this module because the NPC registry already permanently binds the faction to one wallet.

The record emits authored, rotated, revoked, and authority-transferred events. Events contain commitments and public metadata only.

## Lifecycle

Creation starts at revision 1. To rotate revision `N`, compute the new commitment for revision `N + 1`, then call the scope-specific rotate function with `expected_revision = N`. The expected revision prevents a delayed transaction from overwriting newer state.

Revocation clears the active digest and increments the revision. Repeating a revocation is idempotent. Rotation after revocation reactivates the record. Authority transfer also clears and revokes the prior digest.

No reveal or location-publication behavior is part of this module.

## Deployment

A fresh deployment publishes the module from `contracts/world_transponder`, creates a shared `TransponderRegistry`, and records the feature package as both call target and type origin in the combined `npc-deployment.json` manifest. It depends on the base world and `world_npc`; it is not part of the base-world package.

In an upgrade, calls target the latest compatible transponder package while `TransponderScopeKey` derivation and `TransponderCommitment` type checks retain the first package that introduced the module. Preserve the existing registry. Changing the base-world or NPC dependency may require a compatible feature upgrade; the repository does not yet provide an automated per-feature upgrade command.

Run the focused tests with:

```sh
sui move test --path contracts/world_transponder
```
