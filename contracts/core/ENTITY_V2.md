# Entity V2 lifecycle

New entities carry version 2 and a complete `ModuleRegistryKey` dynamic field.
Every module install records its slot and original type ID; uninstall removes
that entry. Both `request_delete` and `delete` require an empty registry, so an
administrator cannot orphan modules containing inventory, escrow, or claimable
assets. Each module's own uninstall handler must enforce its teardown rules.

`begin_module_request<T>` is available only to the package defining installed
state `T`, proven by `Permit<T>`. It verifies the entity version, lock state,
installed state type, and matching requirement slot. The resulting request is
locked and must be handled and completed normally. Modules can use this path to
keep claims and refunds reachable after an owner disables ordinary actions.
Operation handlers must still enforce their own authorization and policy.

`access_cap::assert_valid` allows a module-authored handler to check a capability
version before using its entity ID as the authenticated caller.

## Deployment and legacy entities

Industry requires fresh Entity V2 objects. No V1 migration entry point is
provided: V1 entities have no complete module index, and Move cannot enumerate
their existing dynamic fields. Checking that a caller-supplied list exists
cannot establish that it includes every installed slot. An administrator
approving such a list also does not provide an on-chain proof of completeness.

V2 entry points reject V1 entities. V1 package entry points that check version 1
reject new V2 entities, including the old deletion function that could orphan
modules. Upgrading a package does not retroactively disable historical V1 code
for V1 objects. Do not install industry escrow on those objects or advertise
them as protected by V2 deletion rules. Existing V1 objects need an independently
audited migration design with a provably complete slot inventory before they
can join the new lifecycle. This implementation does not relabel or silently
adopt legacy objects.
