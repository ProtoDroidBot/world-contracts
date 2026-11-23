import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  entityNew,
  shareEntity,
  verifyAdmin,
  verifyOwner,
  verifySponsor,
} from './core.js'
import {
  assertOnline,
  DESIRED_OFFLINE_MODULE,
  installPowerGrid,
  type ModulePowerSpec,
  migrateWith,
  modulePowerArguments,
} from './power.js'
import { type VariantKeyInput, variantKey } from './variant.js'

const INVENTORY_PACKAGE = 'inventory'

function pkg(config: WorldConfig): string {
  return mvrName(config.env, INVENTORY_PACKAGE)
}

export interface ItemRule {
  typeId?: bigint | null
  itemId?: bigint | null
  minQuantity?: bigint | null
  maxQuantity?: bigint | null
}

function requirement(
  tx: Transaction,
  config: WorldConfig,
  fn: string,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::${fn}`,
    arguments: [
      tx.pure.u64(componentId),
      tx.pure.option('u64', rule.typeId ?? null),
      tx.pure.option('u64', rule.itemId ?? null),
      tx.pure.option('u64', rule.minQuantity ?? null),
      tx.pure.option('u64', rule.maxQuantity ?? null),
    ],
  })
}

export function bridgeInRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'bridge_in_requirement', componentId, rule)
}

export function bridgeOutRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'bridge_out_requirement', componentId, rule)
}

export function depositRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'deposit_requirement', componentId, rule)
}

export function withdrawRequirement(
  tx: Transaction,
  config: WorldConfig,
  componentId: bigint,
  rule: ItemRule,
): TransactionResult {
  return requirement(tx, config, 'withdraw_requirement', componentId, rule)
}

export interface InstallInventoryArgs {
  componentId: bigint
  typeId: bigint
  name?: string | null
  capacity: bigint
  power?: ModulePowerSpec
}

/** Install an inventory component on `entity` and close its admin-gated request. */
export function installInventory(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: InstallInventoryArgs,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory::install`,
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      tx.pure.u64(args.typeId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.capacity),
      ...modulePowerArguments(tx, config, args.power ?? DESIRED_OFFLINE_MODULE),
      tx.object.clock(),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Remove the inventory component `componentId`, closing its admin-gated request. */
export function uninstallInventory(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  componentId: bigint,
): void {
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory::uninstall`,
    arguments: [entity, tx.pure.u64(componentId), tx.object.clock()],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/**
 * Move the inventory `componentId` to `to` with its items, without a burn.
 * Both entities must share a tenant. Admin-gated.
 */
export function migrateInventory(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  componentId: bigint,
): void {
  migrateWith(
    tx,
    config,
    `${pkg(config)}::inventory::migrate`,
    from,
    to,
    componentId,
  )
}

export interface CreateStorageUnitArgs {
  inGameId: bigint
  tenant: string
  componentId: bigint
  typeId: bigint
  name?: string | null
  capacity: bigint
  power?: ModulePowerSpec
}

/**
 * Claim an entity, install an inventory component, and share it — the full
 * storage-unit creation flow in one admin-signed transaction.
 */
export function createStorageUnit(
  tx: Transaction,
  config: WorldConfig,
  args: CreateStorageUnitArgs,
): void {
  const [entity, claimReq] = entityNew(tx, config, {
    inGameId: args.inGameId,
    tenant: args.tenant,
  })
  verifyAdmin(tx, config, claimReq)
  completeRequest(tx, config, entity, claimReq)
  installPowerGrid(tx, config, entity)
  installInventory(tx, config, entity, {
    componentId: args.componentId,
    typeId: args.typeId,
    name: args.name,
    capacity: args.capacity,
    power: args.power,
  })
  shareEntity(tx, config, entity)
}

export interface BalanceOfArgs {
  componentId: bigint
  key: VariantKeyInput
}

export interface HasSingletonArgs {
  moduleId: bigint
  authorizedId: string
  itemId: bigint
}

/**
 * Read the balance of variant `key` (base units) in the entity's inventory. Read-only; run under
 * `simulateTransaction` and decode the returned `u64`.
 */
export function balanceOf(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: BalanceOfArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::balance_of`,
    arguments: [
      entity,
      tx.pure.u64(args.componentId),
      variantKey(tx, config, args.key),
    ],
  })
}

/**
 * True if `itemId` is stored in the inventory routed to `authorizedId`.
 * Read-only; run under `simulateTransaction` and decode the returned `bool`.
 * False if that inventory does not exist yet.
 */
export function hasSingleton(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  args: HasSingletonArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory::has_singleton`,
    arguments: [
      entity,
      tx.pure.u64(args.moduleId),
      tx.pure.address(args.authorizedId),
      tx.pure.u64(args.itemId),
    ],
  })
}

export interface BridgeInArgs {
  typeId: bigint
  itemId?: bigint | null
  quantity?: bigint | null
  volume: bigint
}

/** Game-to-chain bridge: mint into the caller's routed inventory. */
export function gameItemToChain(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: BridgeInArgs,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::game_item_to_chain_inventory`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.option('u64', args.itemId ?? null),
      tx.pure.option('u64', args.quantity ?? null),
      tx.pure.u64(args.volume),
    ],
  })
  verifySponsor(tx, config, request)
  assertOnline(tx, config, entity, request)
}

export interface ItemAmount {
  typeId: bigint
  itemId?: bigint | null
  quantity?: bigint | null
}

/** Chain-to-game bridge: burn from the caller's routed inventory. */
export function chainItemToGame(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: ItemAmount,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::chain_item_to_game_inventory`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.option('u64', args.itemId ?? null),
      tx.pure.option('u64', args.quantity ?? null),
    ],
  })
  verifySponsor(tx, config, request)
  assertOnline(tx, config, entity, request)
}

/**
 * Deposit a standalone `Item`. Aborts unless the item came from this entity or one
 * docked at it. Then checks the inventory's grant.
 */
export function deposit(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  item: TransactionArgument,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::deposit`,
    arguments: [entity, request, item],
  })
  assertOnline(tx, config, entity, request)
}

/** Withdraw from the caller's routed inventory as a fresh `Item`. */
export function withdraw(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  args: ItemAmount,
): TransactionResult {
  const item = tx.moveCall({
    target: `${pkg(config)}::inventory::withdraw`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.typeId),
      tx.pure.option('u64', args.itemId ?? null),
      tx.pure.option('u64', args.quantity ?? null),
    ],
  })
  assertOnline(tx, config, entity, request)
  return item
}

export interface DepositFuelItemArgs {
  fuelBayId: bigint
  /** A fuel `Item` withdrawn in this transaction. */
  item: TransactionArgument
  /** The item's frozen `Variant` record (see `deriveVariantId`). */
  variant: string | TransactionArgument
}

/**
 * Burn a fuel `Item` into a fuel bay of the entity. The item must come from this
 * entity or one docked at it, and be `variant`. The next requirement must be the
 * grid's `DepositFuel`; the owner's `ownerCap` authorizes it, and the gas sponsor
 * must be on `AdminACL`.
 */
export function depositFuelItem(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  request: TransactionArgument,
  ownerCap: string | TransactionArgument,
  args: DepositFuelItemArgs,
): void {
  tx.moveCall({
    target: `${pkg(config)}::inventory::deposit_fuel_item`,
    arguments: [
      entity,
      request,
      tx.pure.u64(args.fuelBayId),
      args.item,
      typeof args.variant === 'string' ? tx.object(args.variant) : args.variant,
      tx.object.clock(),
    ],
  })
  verifyOwner(tx, config, entity, request, ownerCap)
  verifySponsor(tx, config, request)
}
