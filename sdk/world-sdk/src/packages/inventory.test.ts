import { bcs } from '@mysten/sui/bcs'
import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import { createWorldClient } from '../client.js'
import type { WorldConfig } from '../config/types.js'
import {
  bridgeInRequirement,
  bridgeOutRequirement,
  chainItemToGame,
  depositFuelItem,
  depositRequirement,
  gameItemToChain,
  hasSingleton,
  withdraw,
  withdrawRequirement,
} from './inventory.js'

const config: WorldConfig = {
  env: 'local',
  chainId: 'inventory-abi-fixture',
  sharedObjects: {
    adminAcl: { id: '0xa', initialSharedVersion: '1', type: 'AdminACL' },
  },
  packageOverrides: {
    core: '0x11',
    inventory: '0x12',
    power: '0x13',
    variant: '0x14',
  },
}
const client = createWorldClient({ config })

async function moveCalls(tx: Transaction) {
  // Resolve the SDK's MVR names using in-memory package IDs before inspecting.
  await tx.toJSON({ client })
  return tx.getData().commands.map((command) => {
    if (command.$kind !== 'MoveCall') throw new Error('Expected a Move call')
    return command.MoveCall
  })
}

type MoveCall = Awaited<ReturnType<typeof moveCalls>>[number]
type MoveCallArgument = MoveCall['arguments'][number]

function pureInput(tx: Transaction, arg: MoveCallArgument) {
  if (arg.$kind !== 'Input') throw new Error('Expected a transaction input')
  const input = tx.getData().inputs[arg.Input]
  if (input.$kind !== 'Pure') throw new Error('Expected a pure input')
  return Buffer.from(input.Pure.bytes, 'base64')
}

describe('modular inventory transaction ABI', () => {
  it('passes variant and singleton selectors in every requirement', async () => {
    const tx = new Transaction()
    for (const requirement of [
      bridgeInRequirement,
      bridgeOutRequirement,
      depositRequirement,
      withdrawRequirement,
    ]) {
      requirement(tx, config, 11n, {
        typeId: 22n,
        variantId: 0n,
        itemId: 33n,
        minQuantity: 44n,
      })
    }
    const calls = await moveCalls(tx)
    expect(calls.map((call) => call.function)).toEqual([
      'bridge_in_requirement',
      'bridge_out_requirement',
      'deposit_requirement',
      'withdraw_requirement',
    ])
    for (const { arguments: [component, ...options] } of calls) {
      expect(bcs.u64().parse(pureInput(tx, component))).toBe('11')
      const selectors = options.map((input) => bcs.option(bcs.u64()).parse(pureInput(tx, input)))
      expect(selectors).toEqual(['22', '0', '33', '44', null])
    }
  })

  it('mints with a Variant and burns or withdraws with a VariantKey', async () => {
    const tx = new Transaction()
    const entity = tx.object('0x1')
    const request = tx.object('0x2')
    const variant = tx.object('0x3')
    const key = { tenant: 'fixture', typeId: 4n, variantId: 5n }

    gameItemToChain(tx, config, entity, request, { variant, itemId: 6n })
    chainItemToGame(tx, config, entity, request, { key, quantity: 7n })
    withdraw(tx, config, entity, request, { key, itemId: 6n })

    const calls = await moveCalls(tx)
    expect(calls.map((call) => call.function)).toEqual([
      'game_item_to_chain_inventory',
      'verify_sponsor',
      'assert_online',
      'new_key',
      'chain_item_to_game_inventory',
      'verify_sponsor',
      'assert_online',
      'new_key',
      'withdraw',
      'assert_online',
    ])
    expect(calls[0].arguments.slice(0, 3)).toEqual([entity, request, variant])
    const selectors = [[0, '6', null], [4, null, '7'], [8, '6', null]] as const
    for (const [index, itemId, quantity] of selectors) {
      const args = calls[index].arguments
      expect(args).toHaveLength(5)
      expect(bcs.option(bcs.u64()).parse(pureInput(tx, args[3]))).toBe(itemId)
      expect(bcs.option(bcs.u64()).parse(pureInput(tx, args[4]))).toBe(quantity)
    }
    expect(calls[4].arguments[2]).toMatchObject({ Result: 3 })
    expect(calls[8].arguments[2]).toMatchObject({ Result: 7 })
  })

  it('encodes singleton lookup and fuel deposit arguments', async () => {
    const tx = new Transaction()
    const entity = tx.object('0x1')
    const request = tx.object('0x2')
    const item = tx.object('0x3')
    const variant = tx.object('0x4')
    hasSingleton(tx, config, entity, { componentId: 11n, itemId: 12n })
    depositFuelItem(tx, config, entity, request, '0x5', {
      item,
      variant,
      fuelBayId: 13n,
    })

    const [lookup, fuel] = await moveCalls(tx)
    expect(lookup.function).toBe('has_singleton')
    expect(lookup.arguments).toHaveLength(3)
    expect(bcs.u64().parse(pureInput(tx, lookup.arguments[1]))).toBe('11')
    expect(bcs.u64().parse(pureInput(tx, lookup.arguments[2]))).toBe('12')
    expect(fuel.function).toBe('deposit_fuel_item')
    expect(fuel.arguments).toHaveLength(6)
    expect(fuel.arguments.slice(0, 4)).toEqual([entity, request, item, variant])
    expect(bcs.u64().parse(pureInput(tx, fuel.arguments[4]))).toBe('13')
  })
})
