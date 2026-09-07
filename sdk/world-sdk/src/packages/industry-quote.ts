import {
  INDUSTRY_LIMITS,
  type IndustryAmount,
  type RecipeLine,
} from './industry.js'

const U64_MAX = (1n << 64n) - 1n

export interface IndustryQuote {
  inputs: IndustryAmount[]
  outputs: IndustryAmount[]
  deficits: IndustryAmount[]
  inputVolume: bigint
  outputVolume: bigint
  durationMs: bigint
}

/** Advisory only: chain admission rechecks the recipe, policy, balance and capacity. */
export function quoteIndustryRecipe(args: {
  inputs: readonly RecipeLine[]
  outputs: readonly RecipeLine[]
  batches: bigint
  maxBatches: bigint
  durationMsPerBatch: bigint
  /** Trusted catalog volumes indexed by type ID. */
  volumes: ReadonlyMap<bigint, bigint>
  available?: readonly IndustryAmount[]
}): IndustryQuote {
  positive(args.batches, 'batches')
  positive(args.maxBatches, 'maxBatches')
  if (args.maxBatches > INDUSTRY_LIMITS.batches)
    throw new Error('maxBatches exceeds industry limit')
  if (
    args.inputs.length > INDUSTRY_LIMITS.inputTypes ||
    args.outputs.length > INDUSTRY_LIMITS.outputTypes
  )
    throw new Error('recipe arrays exceed industry limits')
  if (args.batches > args.maxBatches)
    throw new Error('batches exceeds recipe maximum')
  const inputs = scale(args.inputs, args.batches)
  const outputs = scale(args.outputs, args.batches)
  const available = new Map<bigint, bigint>()
  for (const amount of args.available ?? []) {
    positive(amount.typeId, 'available typeId')
    checked(amount.quantity, 'available quantity')
    available.set(
      amount.typeId,
      checked(
        (available.get(amount.typeId) ?? 0n) + amount.quantity,
        'available quantity',
      ),
    )
  }
  const deficits = inputs.map(({ typeId, quantity }) => ({
    typeId,
    quantity:
      quantity > (available.get(typeId) ?? 0n)
        ? quantity - (available.get(typeId) ?? 0n)
        : 0n,
  }))
  const volume = (amounts: readonly IndustryAmount[]) =>
    amounts.reduce((total, amount) => {
      const unitVolume = args.volumes.get(amount.typeId)
      if (unitVolume === undefined)
        throw new Error(`missing canonical volume for type ${amount.typeId}`)
      positive(unitVolume, 'canonical volume')
      return checked(
        total + checked(amount.quantity * unitVolume, 'line volume'),
        'total volume',
      )
    }, 0n)
  checked(args.durationMsPerBatch, 'durationMsPerBatch')
  return {
    inputs,
    outputs,
    deficits,
    inputVolume: volume(inputs),
    outputVolume: volume(outputs),
    durationMs: checked(args.durationMsPerBatch * args.batches, 'durationMs'),
  }
}

function checked(value: bigint, label: string): bigint {
  if (typeof value !== 'bigint' || value < 0n || value > U64_MAX)
    throw new Error(`${label} must fit u64`)
  return value
}

function positive(value: bigint, label: string): void {
  checked(value, label)
  if (value === 0n) throw new Error(`${label} must be positive`)
}

function scale(
  lines: readonly RecipeLine[],
  batches: bigint,
): IndustryAmount[] {
  if (lines.length === 0) throw new Error('recipe arrays must be non-empty')
  const seen = new Set<bigint>()
  return lines
    .map((line) => {
      positive(line.typeId, 'typeId')
      positive(line.quantityPerBatch, 'quantityPerBatch')
      if (seen.has(line.typeId))
        throw new Error(`duplicate recipe type ${line.typeId}`)
      seen.add(line.typeId)
      return {
        typeId: line.typeId,
        quantity: checked(line.quantityPerBatch * batches, 'scaled quantity'),
      }
    })
    .sort((a, b) => (a.typeId < b.typeId ? -1 : a.typeId > b.typeId ? 1 : 0))
}

/** JSON boundary helper: quantities remain decimal strings, never lossy JS numbers. */
export function industryJson(value: unknown): string {
  return JSON.stringify(value, (_key, field) =>
    typeof field === 'bigint' ? field.toString() : field,
  )
}
