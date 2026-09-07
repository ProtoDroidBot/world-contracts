import type {
  Transaction,
  TransactionArgument,
  TransactionObjectArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import { adminAcl } from '../config/shared-objects.js'
import type { WorldConfig } from '../config/types.js'
import { completeRequest, verifyAdmin } from './core.js'

export const INDUSTRY_KIND = { refining: 0, manufacturing: 1 } as const
export const INDUSTRY_LIMITS = {
  inputTypes: 32,
  outputTypes: 32,
  inputObjects: 64,
  batches: 1_000_000n,
} as const
export type IndustryKind = (typeof INDUSTRY_KIND)[keyof typeof INDUSTRY_KIND]
export type IndustryObject = string | TransactionObjectArgument

export interface RecipeLine {
  typeId: bigint
  quantityPerBatch: bigint
}

export interface IndustryAmount {
  typeId: bigint
  quantity: bigint
}

function pkg(config: WorldConfig): string {
  return config.packageOverrides?.inventory ?? mvrName(config.env, 'inventory')
}

function struct(config: WorldConfig, name: string): string {
  return `${config.packageOverrides?.inventory ?? pkg(config)}::${name}`
}

function object(
  tx: Transaction,
  value: IndustryObject,
): TransactionObjectArgument {
  return typeof value === 'string' ? tx.object(value) : value
}

function acl(tx: Transaction, config: WorldConfig): TransactionObjectArgument {
  return tx.object(adminAcl(config).id)
}

function clock(
  tx: Transaction,
  value?: IndustryObject,
): TransactionObjectArgument {
  return object(tx, value ?? '0x6')
}

/** Create a governed, tenant-scoped catalog. Returns its ID; the catalog is shared. */
export function createItemTypeRegistry(
  tx: Transaction,
  config: WorldConfig,
  tenant: string,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::item_type::create`,
    arguments: [acl(tx, config), tx.pure.string(tenant)],
  })
}

export function registerIndustryItemType(
  tx: Transaction,
  config: WorldConfig,
  types: IndustryObject,
  args: { typeId: bigint; volume: bigint; productionEnabled: boolean },
): void {
  tx.moveCall({
    target: `${pkg(config)}::item_type::register`,
    arguments: [
      object(tx, types),
      acl(tx, config),
      tx.pure.u64(args.typeId),
      tx.pure.u64(args.volume),
      tx.pure.bool(args.productionEnabled),
    ],
  })
}

/** Create a recipe registry pinned to a trusted item catalog. Returns its shared ID. */
export function createRecipeRegistry(
  tx: Transaction,
  config: WorldConfig,
  types: IndustryObject,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::recipe::create`,
    arguments: [object(tx, types), acl(tx, config)],
  })
}

/** Encode independent recipe arrays as real Move values, preserving every line. */
export function makeRecipeLines(
  tx: Transaction,
  config: WorldConfig,
  lines: readonly RecipeLine[],
): TransactionResult {
  const elements = lines.map((line) =>
    tx.moveCall({
      target: `${pkg(config)}::recipe::line`,
      arguments: [tx.pure.u64(line.typeId), tx.pure.u64(line.quantityPerBatch)],
    }),
  )
  return tx.makeMoveVec({
    type: struct(config, 'recipe::RecipeLine'),
    elements,
  })
}

export interface PublishIndustryRecipeArgs {
  types: IndustryObject
  recipes: IndustryObject
  logicalId: bigint
  kind: IndustryKind
  inputs: readonly RecipeLine[]
  outputs: readonly RecipeLine[]
  facilityTypes: readonly bigint[]
  minTier: bigint
  maxBatches: bigint
  durationMsPerBatch: bigint
}

/** Publish one immutable revision of either recipe category. Returns its ID. */
export function publishIndustryRecipe(
  tx: Transaction,
  config: WorldConfig,
  args: PublishIndustryRecipeArgs,
): TransactionResult {
  const inputs = makeRecipeLines(tx, config, args.inputs)
  const outputs = makeRecipeLines(tx, config, args.outputs)
  return tx.moveCall({
    target: `${pkg(config)}::recipe::publish`,
    arguments: [
      object(tx, args.recipes),
      object(tx, args.types),
      acl(tx, config),
      tx.pure.u64(args.logicalId),
      tx.pure.u8(args.kind),
      inputs,
      outputs,
      tx.pure.vector('u64', [...args.facilityTypes]),
      tx.pure.u64(args.minTier),
      tx.pure.u64(args.maxBatches),
      tx.pure.u64(args.durationMsPerBatch),
    ],
  })
}

export function setIndustryRecipeEnabled(
  tx: Transaction,
  config: WorldConfig,
  recipes: IndustryObject,
  recipeId: string | TransactionArgument,
  enabled: boolean,
): void {
  tx.moveCall({
    target: `${pkg(config)}::recipe::set_enabled`,
    arguments: [
      object(tx, recipes),
      acl(tx, config),
      typeof recipeId === 'string' ? tx.pure.id(recipeId) : recipeId,
      tx.pure.bool(enabled),
    ],
  })
}

export interface IndustryFacilityConfig {
  typeId: bigint
  tier: bigint
  kinds: readonly IndustryKind[]
  lanes: bigint
  maxJobs: bigint
  inputCapacity: bigint
  outputCapacity: bigint
}

export interface InstallIndustryArgs extends IndustryFacilityConfig {
  types: IndustryObject
  recipes: IndustryObject
  moduleId: bigint
  name?: string | null
}

export function installIndustry(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: InstallIndustryArgs,
): void {
  const facility = tx.moveCall({
    target: `${pkg(config)}::industry::facility_config`,
    arguments: [
      tx.pure.u64(args.typeId),
      tx.pure.u64(args.tier),
      tx.pure.vector('u8', [...args.kinds]),
      tx.pure.u64(args.lanes),
      tx.pure.u64(args.maxJobs),
      tx.pure.u64(args.inputCapacity),
      tx.pure.u64(args.outputCapacity),
    ],
  })
  const entityArg = object(tx, entity)
  const request = tx.moveCall({
    target: `${pkg(config)}::industry::install`,
    arguments: [
      entityArg,
      object(tx, args.types),
      object(tx, args.recipes),
      acl(tx, config),
      facility,
      tx.pure.u64(args.moduleId),
      tx.pure.option('string', args.name ?? null),
    ],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entityArg, request)
}

export function industryStartRequirement(
  tx: Transaction,
  config: WorldConfig,
  moduleId: bigint,
  maxBatches: bigint,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::start_requirement`,
    arguments: [tx.pure.u64(moduleId), tx.pure.u64(maxBatches)],
  })
}

/** Build vector<ItemV2> from owned object IDs or individual withdrawal results. */
export function makeIndustryItems(
  tx: Transaction,
  config: WorldConfig,
  items: readonly IndustryObject[],
): TransactionResult {
  return tx.makeMoveVec({
    type: struct(config, 'item_v2::ItemV2'),
    elements: [...items],
  })
}

export interface StartIndustryJobArgs {
  types: IndustryObject
  recipes: IndustryObject
  recipe: IndustryObject
  cap: IndustryObject
  /** A vector<ItemV2> result, e.g. withdrawManyV2 or makeIndustryItems. */
  inputs: TransactionArgument
  batches: bigint
  maxFee?: bigint
  /** A mutable Coin<SUI>; defaults to the transaction gas coin for zero-fee jobs. */
  payment?: IndustryObject
  clock?: IndustryObject
}

/** The caller must complete the supplied action Request after starting the job. */
export function startIndustryJob(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  request: TransactionArgument,
  args: StartIndustryJobArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::start_job`,
    arguments: [
      object(tx, entity),
      request,
      object(tx, args.types),
      object(tx, args.recipes),
      object(tx, args.recipe),
      object(tx, args.cap),
      args.payment ? object(tx, args.payment) : tx.gas,
      args.inputs,
      tx.pure.u64(args.batches),
      tx.pure.u64(args.maxFee ?? 0n),
      clock(tx, args.clock),
    ],
  })
}

export interface IndustryJobArgs {
  moduleId: bigint
  jobId: string | TransactionArgument
}

function jobArgs(
  tx: Transaction,
  args: IndustryJobArgs,
): TransactionArgument[] {
  return [
    tx.pure.u64(args.moduleId),
    typeof args.jobId === 'string' ? tx.pure.id(args.jobId) : args.jobId,
  ]
}

/** Permissionless mature-job settlement; the module closes its protected Request. */
export function settleIndustryJob(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs & { types: IndustryObject; clock?: IndustryObject },
): void {
  tx.moveCall({
    target: `${pkg(config)}::industry::settle_job`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      ...jobArgs(tx, args),
      clock(tx, args.clock),
    ],
  })
}

/** Returns the entire output vector for direct bulk deposit or transfer. */
export function claimIndustryOutputs(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs & { cap: IndustryObject },
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::claim_outputs`,
    arguments: [object(tx, entity), object(tx, args.cap), ...jobArgs(tx, args)],
  })
}

export function cancelIndustryJob(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs & { cap: IndustryObject; clock?: IndustryObject },
): void {
  tx.moveCall({
    target: `${pkg(config)}::industry::cancel_job`,
    arguments: [
      object(tx, entity),
      object(tx, args.cap),
      ...jobArgs(tx, args),
      clock(tx, args.clock),
    ],
  })
}

/** Returns [vector<ItemV2>, Coin<SUI>]; both values must be consumed in this PTB. */
export function claimIndustryRefund(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs & { cap: IndustryObject },
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::claim_refund`,
    arguments: [object(tx, entity), object(tx, args.cap), ...jobArgs(tx, args)],
  })
}

export interface IndustryPolicy {
  paused: boolean
  ownerOnly: boolean
  kinds: readonly IndustryKind[]
  allowedRecipes: readonly string[]
  feePerBatch: bigint
  feeRecipient: string
}

export function setIndustryPolicy(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  cap: IndustryObject,
  moduleId: bigint,
  policy: IndustryPolicy,
): void {
  const value = tx.moveCall({
    target: `${pkg(config)}::industry::policy`,
    arguments: [
      tx.pure.bool(policy.paused),
      tx.pure.bool(policy.ownerOnly),
      tx.pure.vector('u8', [...policy.kinds]),
      tx.pure.vector('id', [...policy.allowedRecipes]),
      tx.pure.u64(policy.feePerBatch),
      tx.pure.address(policy.feeRecipient),
    ],
  })
  tx.moveCall({
    target: `${pkg(config)}::industry::set_policy`,
    arguments: [
      object(tx, entity),
      object(tx, cap),
      tx.pure.u64(moduleId),
      value,
    ],
  })
}

export function uninstallIndustry(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  moduleId: bigint,
): void {
  const entityArg = object(tx, entity)
  const request = tx.moveCall({
    target: `${pkg(config)}::industry::uninstall`,
    arguments: [entityArg, tx.pure.u64(moduleId)],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entityArg, request)
}

/** Trusted admin allocation updates; admitted job capacity cannot be revoked. */
export function setIndustryLimits(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: {
    types: IndustryObject
    moduleId: bigint
    lanes: bigint
    maxJobs: bigint
    inputCapacity: bigint
    outputCapacity: bigint
  },
): void {
  tx.moveCall({
    target: `${pkg(config)}::industry::set_limits`,
    arguments: [
      object(tx, entity),
      object(tx, args.types),
      acl(tx, config),
      tx.pure.u64(args.moduleId),
      tx.pure.u64(args.lanes),
      tx.pure.u64(args.maxJobs),
      tx.pure.u64(args.inputCapacity),
      tx.pure.u64(args.outputCapacity),
    ],
  })
}

/** Read-only: simulate and decode using IndustryJobSummaryBcs. */
export function industryJobSummary(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::job_summary`,
    arguments: [object(tx, entity), ...jobArgs(tx, args)],
  })
}

export function industryJobState(
  tx: Transaction,
  config: WorldConfig,
  entity: IndustryObject,
  args: IndustryJobArgs,
): TransactionResult {
  return tx.moveCall({
    target: `${pkg(config)}::industry::job_state`,
    arguments: [object(tx, entity), ...jobArgs(tx, args)],
  })
}
