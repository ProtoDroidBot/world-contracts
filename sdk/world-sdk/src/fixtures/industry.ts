import type { Signer } from '@mysten/sui/cryptography'
import { Transaction } from '@mysten/sui/transactions'
import {
  type ExecutedTransaction,
  signAndExecute,
  type WorldClient,
} from '../client.js'
import type { WorldConfig } from '../config/types.js'
import {
  callerRequirement,
  completeRequest,
  deriveObjectId,
  enableAction,
  entityNew,
  mintAccess,
  shareEntity,
  verifyAdmin,
} from '../packages/core.js'
import {
  createItemTypeRegistry,
  createRecipeRegistry,
  INDUSTRY_KIND,
  type IndustryKind,
  industryStartRequirement,
  installIndustry,
  publishIndustryRecipe,
  type RecipeLine,
  registerIndustryItemType,
} from '../packages/industry.js'
import {
  batchDepositRequirement,
  importIndustryItems,
  installInventoryV2,
} from '../packages/inventory-v2.js'

/** Synthetic localnet data only; none of these IDs are a production game catalog. */
export const INDUSTRY_FIXTURE = {
  industryModule: 7001n,
  sourceModule: 7002n,
  secondSourceModule: 7003n,
  destinationModule: 7004n,
  smallDestinationModule: 7005n,
  facilityType: 9001n,
  types: [
    { typeId: 1001n, volume: 2n },
    { typeId: 1002n, volume: 1n },
    { typeId: 2001n, volume: 1n },
    { typeId: 2002n, volume: 2n },
    { typeId: 2003n, volume: 3n },
  ],
} as const

export interface IndustryFixtureRecipe {
  name: string
  logicalId: bigint
  kind: IndustryKind
  inputs: RecipeLine[]
  outputs: RecipeLine[]
  durationMsPerBatch: bigint
}

const twoInputs = [
  { typeId: 1001n, quantityPerBatch: 100n },
  { typeId: 1002n, quantityPerBatch: 40n },
]
const threeOutputs = [
  { typeId: 2001n, quantityPerBatch: 60n },
  { typeId: 2002n, quantityPerBatch: 25n },
  { typeId: 2003n, quantityPerBatch: 5n },
]
export const INDUSTRY_FIXTURE_RECIPES: readonly IndustryFixtureRecipe[] = [
  {
    name: 'refiningOneToOne',
    logicalId: 1n,
    kind: INDUSTRY_KIND.refining,
    inputs: [twoInputs[0]],
    outputs: [threeOutputs[0]],
    durationMsPerBatch: 0n,
  },
  {
    name: 'refiningOneToMany',
    logicalId: 2n,
    kind: INDUSTRY_KIND.refining,
    inputs: [twoInputs[0]],
    outputs: threeOutputs,
    durationMsPerBatch: 0n,
  },
  {
    name: 'manufacturingManyToOne',
    logicalId: 3n,
    kind: INDUSTRY_KIND.manufacturing,
    inputs: twoInputs,
    outputs: [threeOutputs[0]],
    durationMsPerBatch: 0n,
  },
  {
    name: 'manufacturingManyToMany',
    logicalId: 4n,
    kind: INDUSTRY_KIND.manufacturing,
    inputs: twoInputs,
    outputs: threeOutputs,
    durationMsPerBatch: 0n,
  },
  {
    name: 'timedManufacturing',
    logicalId: 5n,
    kind: INDUSTRY_KIND.manufacturing,
    inputs: twoInputs,
    outputs: threeOutputs,
    durationMsPerBatch: 60_000n,
  },
  {
    name: 'timedRefining',
    logicalId: 6n,
    kind: INDUSTRY_KIND.refining,
    inputs: [twoInputs[0]],
    outputs: threeOutputs,
    durationMsPerBatch: 60_000n,
  },
]

export interface IndustryFixtureDeployment {
  tenant: string
  entityId: string
  ownerCapId: string
  itemTypeRegistryId: string
  recipeRegistryId: string
  recipes: Record<string, string>
}

export function createdObject(
  result: ExecutedTransaction,
  suffix: string,
): string {
  const id = result.effects.changedObjects.find(
    (change) =>
      change.idOperation === 'Created' &&
      result.objectTypes[change.objectId]?.endsWith(suffix),
  )?.objectId
  if (!id)
    throw new Error(`created ${suffix} was not present in ${result.digest}`)
  return id
}

/** Provision isolated localnet catalogs, all cardinalities, assembly, caps and inputs. */
export async function createIndustryFixture(args: {
  client: WorldClient
  config: WorldConfig
  signer: Signer
  tenant: string
  inGameId: bigint
}): Promise<IndustryFixtureDeployment> {
  const { client, config, signer, tenant, inGameId } = args
  if (config.env !== 'local')
    throw new Error('synthetic industry fixtures require localnet')
  const execute = async (transaction: Transaction) => {
    const result = await signAndExecute(client, { signer, transaction })
    await client.waitForTransaction({ digest: result.digest })
    return result
  }
  const typesTx = new Transaction()
  createItemTypeRegistry(typesTx, config, tenant)
  const itemTypeRegistryId = createdObject(
    await execute(typesTx),
    '::item_type::ItemTypeRegistry',
  )

  const registerTx = new Transaction()
  for (const definition of INDUSTRY_FIXTURE.types) {
    registerIndustryItemType(registerTx, config, itemTypeRegistryId, {
      ...definition,
      productionEnabled: true,
    })
  }
  createRecipeRegistry(registerTx, config, itemTypeRegistryId)
  const recipeRegistryId = createdObject(
    await execute(registerTx),
    '::recipe::RecipeRegistry',
  )

  const recipes: Record<string, string> = {}
  for (const recipe of INDUSTRY_FIXTURE_RECIPES) {
    const recipeTx = new Transaction()
    publishIndustryRecipe(recipeTx, config, {
      ...recipe,
      types: itemTypeRegistryId,
      recipes: recipeRegistryId,
      facilityTypes: [INDUSTRY_FIXTURE.facilityType],
      minTier: 1n,
      maxBatches: 100n,
    })
    recipes[recipe.name] = createdObject(
      await execute(recipeTx),
      '::recipe::RecipeRevision',
    )
  }

  const createTx = new Transaction()
  const [entity, claim] = entityNew(createTx, config, { inGameId, tenant })
  verifyAdmin(createTx, config, claim)
  completeRequest(createTx, config, entity, claim)
  for (const moduleId of [
    INDUSTRY_FIXTURE.sourceModule,
    INDUSTRY_FIXTURE.secondSourceModule,
    INDUSTRY_FIXTURE.destinationModule,
    INDUSTRY_FIXTURE.smallDestinationModule,
  ]) {
    installInventoryV2(createTx, config, entity, {
      types: itemTypeRegistryId,
      moduleId,
      typeId: 1n,
      mainCapacity:
        moduleId === INDUSTRY_FIXTURE.smallDestinationModule
          ? 110n
          : 1_000_000n,
      ephemeralCapacity: 1_000_000n,
    })
  }
  installIndustry(createTx, config, entity, {
    types: itemTypeRegistryId,
    recipes: recipeRegistryId,
    moduleId: INDUSTRY_FIXTURE.industryModule,
    typeId: INDUSTRY_FIXTURE.facilityType,
    tier: 1n,
    kinds: [INDUSTRY_KIND.refining, INDUSTRY_KIND.manufacturing],
    lanes: 4n,
    maxJobs: 16n,
    inputCapacity: 100_000n,
    outputCapacity: 100_000n,
  })
  shareEntity(createTx, config, entity)
  await execute(createTx)
  const entityId = deriveObjectId(config, { id: inGameId, tenant })

  const capTx = new Transaction()
  mintAccess(capTx, config, {
    entity: entityId,
    owner: signer.toSuiAddress(),
    transferable: true,
  })
  const ownerCapId = createdObject(
    await execute(capTx),
    '::access_cap::AccessCap',
  )

  const enableTx = new Transaction()
  const e = enableTx.object(entityId)
  enableAction(
    enableTx,
    config,
    e,
    'industry_start',
    [
      callerRequirement(enableTx, config),
      industryStartRequirement(
        enableTx,
        config,
        INDUSTRY_FIXTURE.industryModule,
        100n,
      ),
    ],
    ownerCapId,
  )
  for (const [name, moduleId] of [
    ['industry_deposit', INDUSTRY_FIXTURE.destinationModule],
    ['industry_deposit_small', INDUSTRY_FIXTURE.smallDestinationModule],
  ] as const) {
    enableAction(
      enableTx,
      config,
      e,
      name,
      [
        callerRequirement(enableTx, config),
        batchDepositRequirement(enableTx, config, {
          moduleId,
          ephemeral: false,
          limits: INDUSTRY_FIXTURE.types.map((type) => ({
            typeId: type.typeId,
            quantity: 100_000n,
          })),
        }),
      ],
      ownerCapId,
    )
  }
  importIndustryItems(enableTx, config, e, {
    types: itemTypeRegistryId,
    moduleId: INDUSTRY_FIXTURE.sourceModule,
    beneficiary: entityId,
    transferId: [1],
    amounts: [{ typeId: 1001n, quantity: 10000n }],
  })
  importIndustryItems(enableTx, config, e, {
    types: itemTypeRegistryId,
    moduleId: INDUSTRY_FIXTURE.secondSourceModule,
    beneficiary: entityId,
    transferId: [2],
    amounts: [{ typeId: 1002n, quantity: 10000n }],
  })
  await execute(enableTx)
  return {
    tenant,
    entityId,
    ownerCapId,
    itemTypeRegistryId,
    recipeRegistryId,
    recipes,
  }
}
