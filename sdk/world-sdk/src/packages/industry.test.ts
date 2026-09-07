import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import type { WorldConfig } from '../config/types.js'
import {
  claimIndustryOutputs,
  claimIndustryRefund,
  INDUSTRY_KIND,
  makeIndustryItems,
  publishIndustryRecipe,
  startIndustryJob,
} from './industry.js'
import { industryJson, quoteIndustryRecipe } from './industry-quote.js'
import { decodeIndustryRecipe, IndustryRecipeBcs } from './industry-read.js'
import {
  concatIndustryItems,
  depositManyV2,
  makeIndustryAmounts,
  withdrawManyV2,
} from './inventory-v2.js'

const config: WorldConfig = {
  env: 'local',
  chainId: 'fixture',
  packageOverrides: { core: '0x11', inventory: '0x12' },
  sharedObjects: {
    adminAcl: { id: '0xa1', type: '0x11::admin_service::AdminACL' },
  },
}
const inputs = [
  { typeId: 1001n, quantityPerBatch: 100n },
  { typeId: 1002n, quantityPerBatch: 40n },
]
const outputs = [
  { typeId: 2001n, quantityPerBatch: 60n },
  { typeId: 2002n, quantityPerBatch: 25n },
  { typeId: 2003n, quantityPerBatch: 5n },
]
const volumes = new Map([
  [1001n, 2n],
  [1002n, 1n],
  [2001n, 1n],
  [2002n, 2n],
  [2003n, 3n],
])

function pureU64(tx: Transaction, input: number): bigint {
  const value = tx.getData().inputs[input]
  if (!value.Pure) throw new Error('expected Pure input')
  return BigInt(bcs.u64().parse(Buffer.from(value.Pure.bytes, 'base64')))
}

describe('industry quotes and BCS', () => {
  it('scales an independent 2-to-3 recipe and aggregates fragmented availability', () => {
    const quote = quoteIndustryRecipe({
      inputs,
      outputs,
      batches: 3n,
      maxBatches: 100n,
      durationMsPerBatch: 250n,
      volumes,
      available: [
        { typeId: 1001n, quantity: 100n },
        { typeId: 1001n, quantity: 200n },
        { typeId: 1002n, quantity: 119n },
      ],
    })
    expect(quote.inputs).toEqual([
      { typeId: 1001n, quantity: 300n },
      { typeId: 1002n, quantity: 120n },
    ])
    expect(quote.outputs).toEqual([
      { typeId: 2001n, quantity: 180n },
      { typeId: 2002n, quantity: 75n },
      { typeId: 2003n, quantity: 15n },
    ])
    expect(quote.deficits).toEqual([
      { typeId: 1001n, quantity: 0n },
      { typeId: 1002n, quantity: 1n },
    ])
    expect([quote.inputVolume, quote.outputVolume, quote.durationMs]).toEqual([
      720n,
      375n,
      750n,
    ])
    expect(JSON.parse(industryJson(quote)).inputs[0].quantity).toBe('300')
  })

  it('rejects overflow, duplicates, unknown volume and invalid batch sizes', () => {
    const quote = {
      inputs,
      outputs,
      batches: 1n,
      maxBatches: 10n,
      durationMsPerBatch: 0n,
      volumes,
    }
    expect(() => quoteIndustryRecipe({ ...quote, batches: 0n })).toThrow(
      'positive',
    )
    expect(() => quoteIndustryRecipe({ ...quote, batches: 11n })).toThrow(
      'maximum',
    )
    expect(() =>
      quoteIndustryRecipe({ ...quote, inputs: [inputs[0], inputs[0]] }),
    ).toThrow('duplicate')
    expect(() => quoteIndustryRecipe({ ...quote, volumes: new Map() })).toThrow(
      'missing canonical volume',
    )
    expect(() =>
      quoteIndustryRecipe({
        ...quote,
        batches: 2n,
        inputs: [{ typeId: 1001n, quantityPerBatch: (1n << 64n) - 1n }],
      }),
    ).toThrow('u64')
    expect(() =>
      quoteIndustryRecipe({
        ...quote,
        volumes: new Map([...volumes, [2003n, (1n << 64n) - 1n]]),
      }),
    ).toThrow('u64')
  })

  it('decodes all recipe fields and quantities above Number.MAX_SAFE_INTEGER without precision loss', () => {
    const quantity = 9007199254740993n
    const bytes = IndustryRecipeBcs.serialize({
      id: '0x20',
      version: 1n,
      registry_id: '0x21',
      item_registry_id: '0x22',
      tenant: 'synthetic',
      logical_id: 7n,
      revision: 2n,
      kind: 1,
      inputs: [{ type_id: 1001n, quantity_per_batch: quantity }],
      outputs: outputs.map((line) => ({
        type_id: line.typeId,
        quantity_per_batch: line.quantityPerBatch,
      })),
      facility_types: [9001n],
      min_tier: 1n,
      max_batches: 1n,
      duration_ms_per_batch: 0n,
      digest: [1, 2, 3],
    }).toBytes()
    const decoded = decodeIndustryRecipe(bytes)
    expect(decoded.inputs[0].quantityPerBatch).toBe(quantity)
    expect(decoded.outputs).toEqual(outputs)
    expect(decoded.kind).toBe(INDUSTRY_KIND.manufacturing)
  })
})

describe('industry PTB array routing', () => {
  it.each([
    INDUSTRY_KIND.refining,
    INDUSTRY_KIND.manufacturing,
  ])('publishes kind %s with independent vectors', (kind) => {
    const tx = new Transaction()
    publishIndustryRecipe(tx, config, {
      types: '0x21',
      recipes: '0x22',
      logicalId: 1n,
      kind,
      inputs,
      outputs,
      facilityTypes: [9001n],
      minTier: 1n,
      maxBatches: 3n,
      durationMsPerBatch: 0n,
    })
    const commands = tx.getData().commands
    expect(
      commands
        .filter((c) => c.MakeMoveVec)
        .map((c) => c.MakeMoveVec?.elements.length),
    ).toEqual([2, 3])
    expect(commands.at(-1)?.MoveCall?.function).toBe('publish')
    expect(commands.at(-1)?.MoveCall?.arguments[5]).toMatchObject({ Result: 2 })
    expect(commands.at(-1)?.MoveCall?.arguments[6]).toMatchObject({ Result: 6 })
  })

  it('encodes u64 as lossless BCS and owned assets as ItemV2 elements', () => {
    const tx = new Transaction()
    const value = 9007199254740993n
    makeIndustryAmounts(tx, config, [{ typeId: value, quantity: value }])
    expect(pureU64(tx, 0)).toBe(value)
    expect(pureU64(tx, 1)).toBe(value)
    makeIndustryItems(tx, config, ['0x31', '0x32'])
    const vectors = tx.getData().commands.filter((c) => c.MakeMoveVec)
    expect(vectors.map((c) => c.MakeMoveVec?.type)).toEqual([
      '0x12::item_v2::ItemAmount',
      '0x12::item_v2::ItemV2',
    ])
  })

  it('concatenates withdrawal vectors in Move and routes complete products directly to deposit_many', () => {
    const tx = new Transaction()
    const first = withdrawManyV2(tx, config, '0x31', tx.object('0x41'), {
      types: '0x21',
      amounts: [{ typeId: 1001n, quantity: 300n }],
    })
    const second = withdrawManyV2(tx, config, '0x32', tx.object('0x42'), {
      types: '0x21',
      amounts: [{ typeId: 1002n, quantity: 120n }],
    })
    const combined = concatIndustryItems(tx, config, [first, second])
    const job = startIndustryJob(tx, config, '0x33', tx.object('0x43'), {
      types: '0x21',
      recipes: '0x22',
      recipe: '0x23',
      cap: '0x44',
      inputs: combined,
      batches: 3n,
    })
    const products = claimIndustryOutputs(tx, config, '0x33', {
      cap: '0x44',
      moduleId: 9n,
      jobId: job,
    })
    depositManyV2(tx, config, '0x34', tx.object('0x45'), {
      types: '0x21',
      items: products,
      amounts: outputs.map((line) => ({
        typeId: line.typeId,
        quantity: line.quantityPerBatch * 3n,
      })),
    })
    const commands = tx.getData().commands
    const concatIndex = commands.findIndex(
      (c) => c.MoveCall?.function === 'concat',
    )
    const claimIndex = commands.findIndex(
      (c) => c.MoveCall?.function === 'claim_outputs',
    )
    expect(
      commands.find((c) => c.MoveCall?.function === 'start_job')?.MoveCall
        ?.arguments[7],
    ).toMatchObject({ Result: concatIndex })
    expect(commands.at(-1)?.MoveCall?.arguments[3]).toMatchObject({
      Result: claimIndex,
    })
    expect(
      commands.filter((c) => c.MakeMoveVec?.type?.endsWith('::ItemV2')),
    ).toHaveLength(0)
  })

  it('keeps the refund vector and fee coin as separate transaction results', () => {
    const tx = new Transaction()
    const [items, fee] = claimIndustryRefund(tx, config, '0x31', {
      cap: '0x44',
      moduleId: 9n,
      jobId: '0x55',
    })
    depositManyV2(tx, config, '0x31', tx.object('0x45'), {
      types: '0x21',
      items,
      amounts: [{ typeId: 1001n, quantity: 1n }],
    })
    tx.transferObjects([fee], '0x66')
    const commands = tx.getData().commands
    expect(
      commands.find((c) => c.MoveCall?.function === 'deposit_many')?.MoveCall
        ?.arguments[3],
    ).toMatchObject({ NestedResult: [0, 0] })
    expect(commands.at(-1)?.TransferObjects?.objects[0]).toMatchObject({
      NestedResult: [0, 1],
    })
  })
})
