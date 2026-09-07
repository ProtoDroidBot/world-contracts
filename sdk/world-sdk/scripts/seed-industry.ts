import { readFileSync, writeFileSync } from 'node:fs'
import {
  ITEM_TYPE_REGISTRY,
  RECIPE_REGISTRY,
} from '../src/config/shared-objects.js'
import { createIndustryFixture } from '../src/fixtures/industry.js'
import { loadScriptContext } from './context.js'

const { deployEnv, manifestPath, client, config, keypair } = loadScriptContext()
if (deployEnv !== 'localnet')
  throw new Error('Synthetic industry seed is restricted to localnet')
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
if (manifest.industryFixture) {
  console.log('Synthetic industry fixture already recorded; skipping.')
} else {
  const tenant = 'synthetic-industry-localnet'
  const fixture = await createIndustryFixture({
    client,
    config,
    signer: keypair,
    tenant,
    inGameId: 79001n,
  })
  for (const [key, id, suffix] of [
    [
      ITEM_TYPE_REGISTRY,
      fixture.itemTypeRegistryId,
      'item_type::ItemTypeRegistry',
    ],
    [RECIPE_REGISTRY, fixture.recipeRegistryId, 'recipe::RecipeRegistry'],
  ]) {
    const ref = { id, type: `${config.packageOverrides?.inventory}::${suffix}` }
    manifest.sharedObjects[key] = ref
    manifest.sharedObjects[`${key}:${tenant}`] = ref
  }
  manifest.industryFixture = fixture
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log(`Seeded synthetic industry fixture on ${fixture.entityId}`)
}
