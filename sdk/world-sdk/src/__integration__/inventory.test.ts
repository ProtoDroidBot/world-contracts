import { Transaction } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  interact,
  ownerRequirement,
  verifyOwner,
} from '../packages/core.js'
import {
  bridgeInRequirement,
  createStorageUnit,
  deposit,
  depositRequirement,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../packages/inventory.js'
import { bringInventoryOnline } from './bring-online.js'
import {
  expectSuccess,
  itemVariant,
  loadLocalnetWorld,
  mintAccessCap,
  readBalance,
  readHasSingleton,
  signer,
} from './helpers.js'

// Exercise the inventory bindings in isolation. Create a storage-unit entity,
// mint the owner cap to a plain address, enable owner deposit/withdraw/bridge
// actions, then round-trip a fungible balance and a singleton Item.
const MODULE_ID = 0x51n
const UNIT = 'SU-01'
const FUEL = 88834n
const BLUEPRINT = 77n
const VOL = 2n
const BLUEPRINT_VOL = 500n
const BLUEPRINT_ITEM = 1n

describe('inventory owner round-trip (localnet)', () => {
  const { config, client } = loadLocalnetWorld()

  async function setupOwnerUnit(key: { id: bigint; tenant: string }) {
    const entityId = deriveObjectId(config, key)

    // tx1: create + install + share the storage unit.
    const createTx = new Transaction()
    createStorageUnit(createTx, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name: UNIT,
      capacity: 1000n,
    })
    await expectSuccess(client, createTx)

    // tx2: mint the (transferable) owner cap to a plain address — here the signer.
    const capId = await mintAccessCap(client, config, {
      entity: entityId,
      owner: signer,
      transferable: true,
    })

    // tx3: admin exposes the actions before the owner uses them.
    const enableTx = new Transaction()
    const entity = enableTx.object(entityId)

    enableAdminAction(enableTx, config, entity, 'bridge_in', [
      ownerRequirement(enableTx, config),
      bridgeInRequirement(enableTx, config, MODULE_ID, {}),
    ])
    enableAdminAction(enableTx, config, entity, 'withdraw', [
      ownerRequirement(enableTx, config),
      withdrawRequirement(enableTx, config, MODULE_ID, {}),
    ])
    enableAdminAction(enableTx, config, entity, 'deposit', [
      ownerRequirement(enableTx, config),
      depositRequirement(enableTx, config, MODULE_ID, {}),
    ])
    await expectSuccess(client, enableTx)
    await bringInventoryOnline(
      client,
      config,
      entityId,
      key.tenant,
      capId,
      MODULE_ID,
    )

    return { entityId, capId }
  }

  it('bridges in, withdraws, and deposits back on the main inventory', async () => {
    const tenant = 'inventory-t1'
    const { entityId, capId } = await setupOwnerUnit({ id: 4200n, tenant })
    const itemKey = { tenant, typeId: FUEL, variantId: 0n }
    const variant = await itemVariant(client, config, { ...itemKey, unitVolume: VOL })

    const runTx = new Transaction()
    addSponsors(runTx, config, [signer])
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeRequest = interact(runTx, config, e, 'bridge_in')
    verifyOwner(runTx, config, e, bridgeRequest, c)
    gameItemToChain(runTx, config, e, bridgeRequest, {
      variant,
      quantity: 100n,
    })
    completeRequest(runTx, config, e, bridgeRequest)

    const withdrawRequest = interact(runTx, config, e, 'withdraw')
    verifyOwner(runTx, config, e, withdrawRequest, c)
    const item = withdraw(runTx, config, e, withdrawRequest, {
      key: itemKey,
      quantity: 20n,
    })
    completeRequest(runTx, config, e, withdrawRequest)

    const depositRequest = interact(runTx, config, e, 'deposit')
    verifyOwner(runTx, config, e, depositRequest, c)
    deposit(runTx, config, e, depositRequest, item)
    completeRequest(runTx, config, e, depositRequest)

    await expectSuccess(client, runTx)

    const main = await readBalance(client, config, {
      entity: entityId,
      componentId: MODULE_ID,
      key: itemKey,
    })
    expect(main).toBe(100n)
  })

  it('bridges in, withdraws, and deposits a singleton on the main inventory', async () => {
    const tenant = 'inventory-t1'
    const { entityId, capId } = await setupOwnerUnit({ id: 4210n, tenant })
    const itemKey = { tenant, typeId: BLUEPRINT, variantId: 0n }
    const variant = await itemVariant(client, config, { ...itemKey, unitVolume: BLUEPRINT_VOL })

    const runTx = new Transaction()
    addSponsors(runTx, config, [signer])
    const e = runTx.object(entityId)
    const c = runTx.object(capId)

    const bridgeReqObj = interact(runTx, config, e, 'bridge_in')
    verifyOwner(runTx, config, e, bridgeReqObj, c)
    gameItemToChain(runTx, config, e, bridgeReqObj, {
      variant,
      itemId: BLUEPRINT_ITEM,
    })
    completeRequest(runTx, config, e, bridgeReqObj)

    const wReq = interact(runTx, config, e, 'withdraw')
    verifyOwner(runTx, config, e, wReq, c)
    const item = withdraw(runTx, config, e, wReq, {
      key: itemKey,
      itemId: BLUEPRINT_ITEM,
    })
    completeRequest(runTx, config, e, wReq)

    const dReq = interact(runTx, config, e, 'deposit')
    verifyOwner(runTx, config, e, dReq, c)
    deposit(runTx, config, e, dReq, item)
    completeRequest(runTx, config, e, dReq)

    await expectSuccess(client, runTx)

    const present = await readHasSingleton(client, config, {
      entity: entityId,
      componentId: MODULE_ID,
      itemId: BLUEPRINT_ITEM,
    })
    expect(present).toBe(true)

    const asFungible = await readBalance(client, config, {
      entity: entityId,
      componentId: MODULE_ID,
      key: itemKey,
    })
    expect(asFungible).toBe(0n)
  })
})
