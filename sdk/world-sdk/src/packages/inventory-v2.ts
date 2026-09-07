import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import { adminAcl } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin } from './core.js'
import type { IndustryAmount, IndustryObject } from './industry.js'

function pkg(config: WorldConfig): string {
  return config.packageOverrides?.inventory ?? mvrName(config.env, 'inventory')
}

function object(tx: Transaction, value: IndustryObject) {
  return typeof value === 'string' ? tx.object(value) : value
}

/** Construct Move ItemAmount values before assembling their vector. */
export function makeIndustryAmounts(
  tx: Transaction,
  config: WorldConfig,
  amounts: readonly IndustryAmount[],
): TransactionResult {
  const elements = amounts.map((amount) =>
    tx.moveCall({
      target: `${pkg(config)}::item_v2::amount`,
      arguments: [tx.pure.u64(amount.typeId), tx.pure.u64(amount.quantity)],
    }),
  )
  return tx.makeMoveVec({
    type: `${config.packageOverrides?.inventory ?? pkg(config)}::item_v2::ItemAmount`,
    elements,
  })
}

/** Concatenate vectors in Move; a returned vector must never become an Item element. */
export function concatIndustryItems(
  tx: Transaction,
  config: WorldConfig,
  vectors: readonly TransactionArgument[],
): TransactionArgument {
  if (vectors.length === 0)
    throw new Error('at least one ItemV2 vector is required')
  return vectors.slice(1).reduce(
    (left, right) =>
      tx.moveCall({
        target: `${pkg(config)}::item_v2::concat`,
        arguments: [left, right],
      }),
    vectors[0],
  )
}

export function transferIndustryItems(
  tx: Transaction,
  config: WorldConfig,
  items: TransactionArgument,
  recipient: string,
): void {
  tx.moveCall({
    target: `${pkg(config)}::item_v2::transfer_all`,
    arguments: [items, tx.pure.address(recipient)],
  })
}

export interface InstallInventoryV2Args {
  types: IndustryObject
  moduleId: bigint
  typeId: bigint
  name?: string | null
  mainCapacity: bigint
  ephemeralCapacity: bigint
}

export function installInventoryV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: InstallInventoryV2Args,
): void {
  const entityArg = object(tx, entity)
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory_v2::install`,
    arguments: [
      entityArg,
      object(tx, args.types),
      tx.object(adminAcl(config).id),
      tx.pure.u64(args.moduleId),
      tx.pure.u64(args.typeId),
      tx.pure.option('string', args.name ?? null),
      tx.pure.u64(args.mainCapacity),
      tx.pure.u64(args.ephemeralCapacity),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entityArg, request)
}

export function uninstallInventoryV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  types: IndustryObject,
  moduleId: bigint,
): void {
  const entityArg = object(tx, entity)
  const request = tx.moveCall({
    target: `${pkg(config)}::inventory_v2::uninstall`,
    arguments: [
      entityArg,
      object(tx, types),
      tx.object(adminAcl(config).id),
      tx.pure.u64(moduleId),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entityArg, request)
}

function batchRequirement(
  tx: Transaction,
  config: WorldConfig,
  fn: string,
  args: {
    moduleId: bigint
    ephemeral: boolean
    limits: readonly IndustryAmount[]
  },
): TransactionResult {
  const amounts = makeIndustryAmounts(tx, config, args.limits)
  return tx.moveCall({
    target: `${pkg(config)}::inventory_v2::${fn}`,
    arguments: [
      tx.pure.u64(args.moduleId),
      tx.pure.bool(args.ephemeral),
      amounts,
    ],
  })
}

export function batchWithdrawalRequirement(
  tx: Transaction,
  config: WorldConfig,
  args: {
    moduleId: bigint
    ephemeral: boolean
    limits: readonly IndustryAmount[]
  },
): TransactionResult {
  return batchRequirement(tx, config, 'batch_withdrawal_requirement', args)
}

export function batchDepositRequirement(
  tx: Transaction,
  config: WorldConfig,
  args: {
    moduleId: bigint
    ephemeral: boolean
    limits: readonly IndustryAmount[]
  },
): TransactionResult {
  return batchRequirement(tx, config, 'batch_deposit_requirement', args)
}

export function withdrawManyV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  request: TransactionArgument,
  args: { types: IndustryObject; amounts: readonly IndustryAmount[] },
): TransactionResult {
  const amounts = makeIndustryAmounts(tx, config, args.amounts)
  return tx.moveCall({
    target: `${pkg(config)}::inventory_v2::withdraw_many`,
    arguments: [object(tx, entity), object(tx, args.types), request, amounts],
  })
}

/** Deposit the complete vector and its exact aggregate amounts using one requirement. */
export function depositManyV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  request: TransactionArgument,
  args: {
    types: IndustryObject
    items: TransactionArgument
    amounts: readonly IndustryAmount[]
  },
): void {
  const amounts = makeIndustryAmounts(tx, config, args.amounts)
  tx.moveCall({
    target: `${pkg(config)}::inventory_v2::deposit_many`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      request,
      args.items,
      amounts,
    ],
  })
}

export function importIndustryItems(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: {
    types: IndustryObject
    moduleId: bigint
    beneficiary: string
    transferId: readonly number[]
    amounts: readonly IndustryAmount[]
  },
): void {
  const amounts = makeIndustryAmounts(tx, config, args.amounts)
  tx.moveCall({
    target: `${pkg(config)}::inventory_v2::import_items`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      tx.object(adminAcl(config).id),
      tx.pure.u64(args.moduleId),
      tx.pure.id(args.beneficiary),
      tx.pure.vector('u8', [...args.transferId]),
      amounts,
    ],
  })
}

export interface OwnedIndustryWithdrawalArgs {
  types: IndustryObject
  cap: IndustryObject
  moduleId: bigint
  amounts: readonly IndustryAmount[]
}

export function withdrawOwnedV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: OwnedIndustryWithdrawalArgs,
): TransactionResult {
  const amounts = makeIndustryAmounts(tx, config, args.amounts)
  return tx.moveCall({
    target: `${pkg(config)}::inventory_v2::withdraw_owned`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      object(tx, args.cap),
      tx.pure.u64(args.moduleId),
      amounts,
    ],
  })
}

export function exportIndustryItems(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: OwnedIndustryWithdrawalArgs,
): TransactionResult {
  const amounts = makeIndustryAmounts(tx, config, args.amounts)
  return tx.moveCall({
    target: `${pkg(config)}::inventory_v2::export_items`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      object(tx, args.cap),
      tx.pure.u64(args.moduleId),
      amounts,
    ],
  })
}

/** Read-only PTB call; simulate and decode the returned u64. */
export function balanceOfV2(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: { moduleId: bigint; beneficiary: string; typeId: bigint },
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::inventory_v2::balance_of`,
    arguments: [
      object(tx, entity),
      tx.pure.u64(args.moduleId),
      tx.pure.id(args.beneficiary),
      tx.pure.u64(args.typeId),
    ],
  })
}
