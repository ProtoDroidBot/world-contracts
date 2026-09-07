import { bcs } from '@mysten/sui/bcs'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import { describe, expect, it } from 'vitest'
import {
  createdObject,
  createIndustryFixture,
  INDUSTRY_FIXTURE as F,
  INDUSTRY_FIXTURE_RECIPES,
  type IndustryFixtureDeployment,
} from '../fixtures/industry.js'
import {
  callerRequirement,
  completeRequest,
  disableAction,
  enableAction,
  entityNew,
  interact,
  mintAccess,
  shareEntity,
  verifyAdmin,
  verifyCaller,
  verifyProximity,
} from '../packages/core.js'
import {
  cancelIndustryJob,
  claimIndustryOutputs,
  claimIndustryRefund,
  type IndustryAmount,
  publishIndustryRecipe,
  registerIndustryItemType,
  setIndustryPolicy,
  settleIndustryJob,
  startIndustryJob,
} from '../packages/industry.js'
import {
  decodeIndustryEvent,
  readIndustryJob,
  readIndustryRecipe,
} from '../packages/industry-read.js'
import {
  balanceOfV2,
  batchDepositRequirement,
  concatIndustryItems,
  depositManyV2,
  importIndustryItems,
  transferIndustryItems,
  withdrawOwnedV2,
} from '../packages/inventory-v2.js'
import { expectSuccess, keypair, loadLocalnetWorld, signer } from './helpers.js'

// The catalogs and assembly are provisioned here; no game dataset or seed state is required.
describe('unified industry arrays (synthetic localnet)', () => {
  const { config, client } = loadLocalnetWorld()
  let fixture: IndustryFixtureDeployment

  const readBalance = async (moduleId: bigint, typeId: bigint) => {
    const tx = new Transaction()
    tx.setSender(signer)
    balanceOfV2(tx, config, fixture.entityId, {
      moduleId,
      beneficiary: fixture.entityId,
      typeId,
    })
    const result = await client.simulateTransaction({
      transaction: tx,
      include: { commandResults: true },
    })
    if (result.FailedTransaction)
      throw new Error(result.FailedTransaction.status.error?.message)
    return BigInt(bcs.u64().parse(result.commandResults[0].returnValues[0].bcs))
  }

  const openStart = (tx: Transaction, cap = fixture.ownerCapId) => {
    const entity = tx.object(fixture.entityId)
    const request = interact(tx, config, entity, 'industry_start', [])
    verifyProximity(tx, config, request, [])
    verifyCaller(tx, config, request, cap)
    return request
  }

  const withdrawInputs = (tx: Transaction, amounts: IndustryAmount[]) =>
    concatIndustryItems(
      tx,
      config,
      amounts.map((amount) =>
        withdrawOwnedV2(tx, config, fixture.entityId, {
          types: fixture.itemTypeRegistryId,
          cap: fixture.ownerCapId,
          moduleId:
            amount.typeId === 1001n ? F.sourceModule : F.secondSourceModule,
          amounts: [amount],
        }),
      ),
    )

  const start = (
    tx: Transaction,
    recipe: string,
    inputs: TransactionArgument,
    batches = 1n,
    cap = fixture.ownerCapId,
  ) => {
    const req = openStart(tx, cap)
    const job = startIndustryJob(tx, config, fixture.entityId, req, {
      types: fixture.itemTypeRegistryId,
      recipes: fixture.recipeRegistryId,
      recipe,
      cap,
      inputs,
      batches,
    })
    completeRequest(tx, config, tx.object(fixture.entityId), req)
    return job
  }

  const deposit = (
    tx: Transaction,
    items: TransactionArgument,
    amounts: IndustryAmount[],
    small = false,
  ) => {
    const entity = tx.object(fixture.entityId)
    const req = interact(
      tx,
      config,
      entity,
      small ? 'industry_deposit_small' : 'industry_deposit',
      [],
    )
    verifyProximity(tx, config, req, [])
    verifyCaller(tx, config, req, fixture.ownerCapId)
    depositManyV2(tx, config, entity, req, {
      types: fixture.itemTypeRegistryId,
      items,
      amounts,
    })
    completeRequest(tx, config, entity, req)
  }

  it('runs all four cardinalities, preserves a failed final deposit, and recovers customer jobs after actions are disabled', async () => {
    fixture = await createIndustryFixture({
      client,
      config,
      signer: keypair,
      tenant: `industry-sdk-${Date.now()}`,
      inGameId: 80001n,
    })
    const totals = new Map<bigint, bigint>()
    for (const recipe of INDUSTRY_FIXTURE_RECIPES.filter(
      (value) => value.durationMsPerBatch === 0n,
    )) {
      const batches = 3n
      const inputAmounts = recipe.inputs.map((line) => ({
        typeId: line.typeId,
        quantity: line.quantityPerBatch * batches,
      }))
      const outputAmounts = recipe.outputs.map((line) => ({
        typeId: line.typeId,
        quantity: line.quantityPerBatch * batches,
      }))
      const tx = new Transaction()
      const inputs = withdrawInputs(tx, inputAmounts)
      const jobId = start(tx, fixture.recipes[recipe.name], inputs, batches)
      settleIndustryJob(tx, config, fixture.entityId, {
        types: fixture.itemTypeRegistryId,
        moduleId: F.industryModule,
        jobId,
      })
      const products = claimIndustryOutputs(tx, config, fixture.entityId, {
        cap: fixture.ownerCapId,
        moduleId: F.industryModule,
        jobId,
      })
      deposit(tx, products, outputAmounts)
      const result = await expectSuccess(client, tx)
      const completed = result.events
        .filter((event) => event.eventType.endsWith('::IndustryJobCompleted'))
        .map(decodeIndustryEvent)
      expect(completed[0].inputs).toEqual(inputAmounts)
      expect(completed[0].outputs).toEqual(outputAmounts)
      expect(completed[0].kind).toBe(recipe.kind)
      for (const amount of outputAmounts)
        totals.set(
          amount.typeId,
          (totals.get(amount.typeId) ?? 0n) + amount.quantity,
        )
    }
    for (const [typeId, total] of totals)
      expect(await readBalance(F.destinationModule, typeId)).toBe(total)
    const recipe = await readIndustryRecipe(
      client,
      fixture.recipes.manufacturingManyToMany,
    )
    expect(recipe.inputs).toHaveLength(2)
    expect(recipe.outputs).toHaveLength(3)

    const inputAmounts = recipe.inputs.map((line) => ({
      typeId: line.typeId,
      quantity: line.quantityPerBatch,
    }))
    const outputAmounts = recipe.outputs.map((line) => ({
      typeId: line.typeId,
      quantity: line.quantityPerBatch,
    }))
    const before = await readBalance(F.sourceModule, 1001n)
    // Final output line exceeds the 110-unit destination; the entire PTB rolls back.
    const failTx = new Transaction()
    const failingJob = start(
      failTx,
      recipe.id,
      withdrawInputs(failTx, inputAmounts),
    )
    settleIndustryJob(failTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.industryModule,
      jobId: failingJob,
    })
    deposit(
      failTx,
      claimIndustryOutputs(failTx, config, fixture.entityId, {
        cap: fixture.ownerCapId,
        moduleId: F.industryModule,
        jobId: failingJob,
      }),
      outputAmounts,
      true,
    )
    await expect(expectSuccess(client, failTx)).rejects.toThrow()
    expect(await readBalance(F.sourceModule, 1001n)).toBe(before)
    for (const amount of outputAmounts)
      expect(await readBalance(F.smallDestinationModule, amount.typeId)).toBe(
        0n,
      )

    // A separately committed completion remains claimable after delivery fails.
    const finishTx = new Transaction()
    const funded = start(
      finishTx,
      recipe.id,
      withdrawInputs(finishTx, inputAmounts),
    )
    settleIndustryJob(finishTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.industryModule,
      jobId: funded,
    })
    const finished = await expectSuccess(client, finishTx)
    const completedEvent = finished.events.find((event) =>
      event.eventType.endsWith('::IndustryJobCompleted'),
    )
    if (!completedEvent) throw new Error('missing job completion event')
    const jobId = decodeIndustryEvent(completedEvent).jobId
    const rejectedClaimTx = new Transaction()
    deposit(
      rejectedClaimTx,
      claimIndustryOutputs(rejectedClaimTx, config, fixture.entityId, {
        cap: fixture.ownerCapId,
        moduleId: F.industryModule,
        jobId,
      }),
      outputAmounts,
      true,
    )
    await expect(expectSuccess(client, rejectedClaimTx)).rejects.toThrow()
    const retryTx = new Transaction()
    deposit(
      retryTx,
      claimIndustryOutputs(retryTx, config, fixture.entityId, {
        cap: fixture.ownerCapId,
        moduleId: F.industryModule,
        jobId,
      }),
      outputAmounts,
    )
    await expectSuccess(client, retryTx)

    // Use a second entity principal as the customer, held by the same test signer.
    const customerTx = new Transaction()
    const [customer, customerReq] = entityNew(customerTx, config, {
      inGameId: 80002n,
      tenant: fixture.tenant,
    })
    verifyAdmin(customerTx, config, customerReq)
    completeRequest(customerTx, config, customer, customerReq)
    shareEntity(customerTx, config, customer)
    const customerId = createdObject(
      await expectSuccess(client, customerTx),
      '::entity::Entity',
    )
    const mintTx = new Transaction()
    mintAccess(mintTx, config, {
      entity: customerId,
      owner: signer,
      transferable: true,
    })
    const customerCap = createdObject(
      await expectSuccess(client, mintTx),
      '::access_cap::AccessCap',
    )
    const policyTx = new Transaction()
    setIndustryPolicy(
      policyTx,
      config,
      fixture.entityId,
      fixture.ownerCapId,
      F.industryModule,
      {
        paused: false,
        ownerOnly: false,
        kinds: [0, 1],
        allowedRecipes: [],
        feePerBatch: 0n,
        feeRecipient: signer,
      },
    )
    await expectSuccess(client, policyTx)
    const customerJobsTx = new Transaction()
    start(
      customerJobsTx,
      recipe.id,
      withdrawInputs(customerJobsTx, inputAmounts),
      1n,
      customerCap,
    )
    start(
      customerJobsTx,
      fixture.recipes.timedManufacturing,
      withdrawInputs(customerJobsTx, inputAmounts),
      1n,
      customerCap,
    )
    const customerJobs = (await expectSuccess(client, customerJobsTx)).events
      .filter((event) => event.eventType.endsWith('::IndustryJobStarted'))
      .map(decodeIndustryEvent)
    expect(customerJobs.map((job) => job.beneficiary)).toEqual([
      customerId,
      customerId,
    ])
    const customerSnapshot = await readIndustryJob(client, config, {
      entity: fixture.entityId,
      moduleId: F.industryModule,
      jobId: customerJobs[1].jobId,
      sender: signer,
    })
    expect(customerSnapshot.beneficiary).toBe(customerId)
    expect(customerSnapshot.state).toBe(0)
    const earlyTx = new Transaction()
    settleIndustryJob(earlyTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.industryModule,
      jobId: customerJobs[1].jobId,
    })
    await expect(expectSuccess(client, earlyTx)).rejects.toThrow()
    const disableTx = new Transaction()
    for (const action of [
      'industry_start',
      'industry_deposit',
      'industry_deposit_small',
    ])
      disableAction(
        disableTx,
        config,
        disableTx.object(fixture.entityId),
        action,
        fixture.ownerCapId,
      )
    setIndustryPolicy(
      disableTx,
      config,
      fixture.entityId,
      fixture.ownerCapId,
      F.industryModule,
      {
        paused: true,
        ownerOnly: true,
        kinds: [0],
        allowedRecipes: [],
        feePerBatch: 0n,
        feeRecipient: signer,
      },
    )
    await expectSuccess(client, disableTx)
    const recoverTx = new Transaction()
    settleIndustryJob(recoverTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.industryModule,
      jobId: customerJobs[0].jobId,
    })
    transferIndustryItems(
      recoverTx,
      config,
      claimIndustryOutputs(recoverTx, config, fixture.entityId, {
        cap: customerCap,
        moduleId: F.industryModule,
        jobId: customerJobs[0].jobId,
      }),
      signer,
    )
    cancelIndustryJob(recoverTx, config, fixture.entityId, {
      cap: customerCap,
      moduleId: F.industryModule,
      jobId: customerJobs[1].jobId,
    })
    const [refund, fee] = claimIndustryRefund(
      recoverTx,
      config,
      fixture.entityId,
      {
        cap: customerCap,
        moduleId: F.industryModule,
        jobId: customerJobs[1].jobId,
      },
    )
    transferIndustryItems(recoverTx, config, refund, signer)
    recoverTx.transferObjects([fee], signer)
    const recovered = await expectSuccess(client, recoverTx)
    expect(
      recovered.events
        .filter((event) => event.eventType.endsWith('::IndustryInputsRefunded'))
        .map(decodeIndustryEvent)[0].inputs,
    ).toEqual(inputAmounts)
    const duplicateTx = new Transaction()
    transferIndustryItems(
      duplicateTx,
      config,
      claimIndustryOutputs(duplicateTx, config, fixture.entityId, {
        cap: customerCap,
        moduleId: F.industryModule,
        jobId: customerJobs[0].jobId,
      }),
      signer,
    )
    await expect(expectSuccess(client, duplicateTx)).rejects.toThrow()
  }, 300_000)

  it('funds 32 input types as 64 fragmented stacks and delivers all 32 output types in one PTB', async () => {
    fixture = await createIndustryFixture({
      client,
      config,
      signer: keypair,
      tenant: `industry-max-${Date.now()}`,
      inGameId: 81001n,
    })
    const inputAmounts = Array.from({ length: 32 }, (_, index) => ({
      typeId: 3001n + BigInt(index),
      quantity: 2n,
    }))
    const outputAmounts = Array.from({ length: 32 }, (_, index) => ({
      typeId: 4001n + BigInt(index),
      quantity: 1n,
    }))
    const registerTx = new Transaction()
    for (const amount of [...inputAmounts, ...outputAmounts]) {
      registerIndustryItemType(registerTx, config, fixture.itemTypeRegistryId, {
        typeId: amount.typeId,
        volume: 1n,
        productionEnabled: true,
      })
    }
    await expectSuccess(client, registerTx)
    const recipeTx = new Transaction()
    publishIndustryRecipe(recipeTx, config, {
      types: fixture.itemTypeRegistryId,
      recipes: fixture.recipeRegistryId,
      logicalId: 100n,
      kind: 1,
      inputs: inputAmounts.map((amount) => ({
        typeId: amount.typeId,
        quantityPerBatch: amount.quantity,
      })),
      outputs: outputAmounts.map((amount) => ({
        typeId: amount.typeId,
        quantityPerBatch: amount.quantity,
      })),
      facilityTypes: [F.facilityType],
      minTier: 1n,
      maxBatches: 1n,
      durationMsPerBatch: 0n,
    })
    const recipeId = createdObject(
      await expectSuccess(client, recipeTx),
      '::recipe::RecipeRevision',
    )
    const prepareTx = new Transaction()
    importIndustryItems(prepareTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.sourceModule,
      beneficiary: fixture.entityId,
      transferId: [3],
      amounts: inputAmounts,
    })
    enableAction(
      prepareTx,
      config,
      prepareTx.object(fixture.entityId),
      'max_output_deposit',
      [
        callerRequirement(prepareTx, config),
        batchDepositRequirement(prepareTx, config, {
          moduleId: F.destinationModule,
          ephemeral: false,
          limits: outputAmounts,
        }),
      ],
      fixture.ownerCapId,
    )
    await expectSuccess(client, prepareTx)
    const maxTx = new Transaction()
    const vectors = inputAmounts.flatMap((amount) =>
      [0, 1].map(() =>
        withdrawOwnedV2(maxTx, config, fixture.entityId, {
          types: fixture.itemTypeRegistryId,
          cap: fixture.ownerCapId,
          moduleId: F.sourceModule,
          amounts: [{ typeId: amount.typeId, quantity: 1n }],
        }),
      ),
    )
    const jobId = start(
      maxTx,
      recipeId,
      concatIndustryItems(maxTx, config, vectors),
    )
    settleIndustryJob(maxTx, config, fixture.entityId, {
      types: fixture.itemTypeRegistryId,
      moduleId: F.industryModule,
      jobId,
    })
    const products = claimIndustryOutputs(maxTx, config, fixture.entityId, {
      cap: fixture.ownerCapId,
      moduleId: F.industryModule,
      jobId,
    })
    const req = interact(
      maxTx,
      config,
      maxTx.object(fixture.entityId),
      'max_output_deposit',
      [],
    )
    verifyProximity(maxTx, config, req, [])
    verifyCaller(maxTx, config, req, fixture.ownerCapId)
    depositManyV2(maxTx, config, fixture.entityId, req, {
      types: fixture.itemTypeRegistryId,
      items: products,
      amounts: outputAmounts,
    })
    completeRequest(maxTx, config, maxTx.object(fixture.entityId), req)
    const maxResult = await expectSuccess(client, maxTx)
    const completed = maxResult.events
      .filter((event) => event.eventType.endsWith('::IndustryJobCompleted'))
      .map(decodeIndustryEvent)
    expect(completed[0].inputs).toEqual(inputAmounts)
    expect(completed[0].outputs).toEqual(outputAmounts)
    for (const amount of outputAmounts)
      expect(await readBalance(F.destinationModule, amount.typeId)).toBe(1n)
    for (const amount of inputAmounts)
      expect(await readBalance(F.sourceModule, amount.typeId)).toBe(0n)
  }, 300_000)
})
