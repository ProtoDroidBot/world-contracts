import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import type { WorldClient } from '../client.js'
import type { WorldConfig } from '../config/types.js'
import type { IndustryKind, RecipeLine } from './industry.js'
import { industryJobState, industryJobSummary } from './industry.js'

/** Field order mirrors inventory::recipe::RecipeLine and RecipeRevision. */
export const IndustryRecipeLineBcs = bcs.struct('RecipeLine', {
  type_id: bcs.u64(),
  quantity_per_batch: bcs.u64(),
})
export const IndustryAmountBcs = bcs.struct('ItemAmount', {
  type_id: bcs.u64(),
  quantity: bcs.u64(),
})
export const IndustryRecipeBcs = bcs.struct('RecipeRevision', {
  id: bcs.Address,
  version: bcs.u64(),
  registry_id: bcs.Address,
  item_registry_id: bcs.Address,
  tenant: bcs.string(),
  logical_id: bcs.u64(),
  revision: bcs.u64(),
  kind: bcs.u8(),
  inputs: bcs.vector(IndustryRecipeLineBcs),
  outputs: bcs.vector(IndustryRecipeLineBcs),
  facility_types: bcs.vector(bcs.u64()),
  min_tier: bcs.u64(),
  max_batches: bcs.u64(),
  duration_ms_per_batch: bcs.u64(),
  digest: bcs.vector(bcs.u8()),
})

export interface IndustryRecipeSnapshot {
  id: string
  version: bigint
  registryId: string
  itemRegistryId: string
  tenant: string
  logicalId: bigint
  revision: bigint
  kind: IndustryKind
  inputs: RecipeLine[]
  outputs: RecipeLine[]
  facilityTypes: bigint[]
  minTier: bigint
  maxBatches: bigint
  durationMsPerBatch: bigint
  digest: number[]
}

export function decodeIndustryRecipe(
  bytes: Uint8Array,
): IndustryRecipeSnapshot {
  const value = IndustryRecipeBcs.parse(bytes)
  if (value.version !== '1')
    throw new Error(`unsupported recipe schema ${value.version}`)
  if (value.kind !== 0 && value.kind !== 1)
    throw new Error(`unsupported recipe kind ${value.kind}`)
  const lines = (items: typeof value.inputs): RecipeLine[] =>
    items.map((line) => ({
      typeId: BigInt(line.type_id),
      quantityPerBatch: BigInt(line.quantity_per_batch),
    }))
  return {
    id: value.id,
    version: BigInt(value.version),
    registryId: value.registry_id,
    itemRegistryId: value.item_registry_id,
    tenant: value.tenant,
    logicalId: BigInt(value.logical_id),
    revision: BigInt(value.revision),
    kind: value.kind,
    inputs: lines(value.inputs),
    outputs: lines(value.outputs),
    facilityTypes: value.facility_types.map(BigInt),
    minTier: BigInt(value.min_tier),
    maxBatches: BigInt(value.max_batches),
    durationMsPerBatch: BigInt(value.duration_ms_per_batch),
    digest: value.digest,
  }
}

/** Decode BCS directly so all u64 fields are lossless and independent of RPC JSON shape. */
export async function readIndustryRecipe(
  client: WorldClient,
  recipeId: string,
): Promise<IndustryRecipeSnapshot> {
  const { object } = await client.getObject({
    objectId: recipeId,
    include: { content: true },
  })
  if (!object.type.endsWith('::recipe::RecipeRevision'))
    throw new Error('object is not a RecipeRevision')
  return decodeIndustryRecipe(object.content)
}

/** This projection is shared by every unified industry lifecycle event. */
export const IndustryJobSummaryBcs = bcs.struct('JobSummary', {
  schema_version: bcs.u64(),
  job_id: bcs.Address,
  entity_id: bcs.Address,
  module_id: bcs.u64(),
  tenant: bcs.string(),
  beneficiary: bcs.Address,
  recipe_id: bcs.Address,
  recipe_digest: bcs.vector(bcs.u8()),
  kind: bcs.u8(),
  batches: bcs.u64(),
  inputs: bcs.vector(IndustryAmountBcs),
  outputs: bcs.vector(IndustryAmountBcs),
  started_at_ms: bcs.u64(),
  ready_at_ms: bcs.u64(),
  fee: bcs.u64(),
})

export function decodeIndustryJobSummary(bytes: Uint8Array) {
  const value = IndustryJobSummaryBcs.parse(bytes)
  if (value.schema_version !== '1')
    throw new Error(`unsupported industry job schema ${value.schema_version}`)
  if (value.kind !== 0 && value.kind !== 1)
    throw new Error(`unsupported recipe kind ${value.kind}`)
  const amounts = (lines: typeof value.inputs) =>
    lines.map((line) => ({
      typeId: BigInt(line.type_id),
      quantity: BigInt(line.quantity),
    }))
  return {
    schemaVersion: BigInt(value.schema_version),
    jobId: value.job_id,
    entityId: value.entity_id,
    moduleId: BigInt(value.module_id),
    tenant: value.tenant,
    beneficiary: value.beneficiary,
    recipeId: value.recipe_id,
    recipeDigest: value.recipe_digest,
    kind: value.kind as IndustryKind,
    batches: BigInt(value.batches),
    inputs: amounts(value.inputs),
    outputs: amounts(value.outputs),
    startedAtMs: BigInt(value.started_at_ms),
    readyAtMs: BigInt(value.ready_at_ms),
    fee: BigInt(value.fee),
  }
}

export type IndustryJobSnapshot = ReturnType<typeof decodeIndustryJobSummary>

/** Lifecycle events contain a single JobSummary field, with the same BCS bytes. */
export function decodeIndustryEvent(event: {
  eventType: string
  bcs: Uint8Array
}): IndustryJobSnapshot {
  if (
    !/::industry::Industry(JobStarted|JobCompleted|JobCancelled|OutputsClaimed|InputsRefunded)$/.test(
      event.eventType,
    )
  ) {
    throw new Error('not a supported industry lifecycle event')
  }
  return decodeIndustryJobSummary(event.bcs)
}

export const INDUSTRY_JOB_STATE = {
  running: 0,
  completed: 1,
  cancelled: 2,
} as const
export type IndustryJobState =
  (typeof INDUSTRY_JOB_STATE)[keyof typeof INDUSTRY_JOB_STATE]

/** Read a funded job's immutable commitment and current state without modifying it. */
export async function readIndustryJob(
  client: WorldClient,
  config: WorldConfig,
  args: { entity: string; moduleId: bigint; jobId: string; sender: string },
): Promise<IndustryJobSnapshot & { state: IndustryJobState }> {
  const tx = new Transaction()
  tx.setSender(args.sender)
  industryJobSummary(tx, config, args.entity, args)
  industryJobState(tx, config, args.entity, args)
  const result = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  if (result.FailedTransaction)
    throw new Error(
      `industry job query failed: ${result.FailedTransaction.status.error?.message ?? 'unknown error'}`,
    )
  const summary = result.commandResults[0]?.returnValues[0]
  const stateValue = result.commandResults[1]?.returnValues[0]
  if (!summary || !stateValue)
    throw new Error('industry job query returned no summary or state')
  const state = bcs.u8().parse(stateValue.bcs)
  if (state !== 0 && state !== 1 && state !== 2)
    throw new Error(`unsupported industry job state ${state}`)
  return { ...decodeIndustryJobSummary(summary.bcs), state }
}
