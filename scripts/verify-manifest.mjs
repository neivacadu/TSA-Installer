import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const policy = JSON.parse(await readFile(resolve('config/release-policy.json'), 'utf8'))
const manifestPath = process.argv[2] ?? 'manifests/tsa-macos-first-release.draft.json'
const manifest = JSON.parse(await readFile(resolve(manifestPath), 'utf8'))
const errors = []
if (manifest.schema_version !== 'tsa.distribution.release/v1') errors.push('schema_version')
if (!['DRAFT', 'PUBLISHED', 'REVOKED'].includes(manifest.state)) errors.push('state')
if (manifest.product?.name !== 'TSA') errors.push('product.name')
if (manifest.product?.app_id !== policy.appId) errors.push('product.app_id')
if (manifest.dna?.source_repository !== `https://github.com/${policy.dnaRepository}`) errors.push('dna.source_repository')
if (manifest.dna?.approved_commit !== policy.dnaApprovedCommit) errors.push('dna.approved_commit')
if (manifest.dna?.release_version !== policy.dnaReleaseVersion) errors.push('dna.release_version')
if (manifest.dna?.manifest_url !== policy.dnaManifestUrl) errors.push('dna.manifest_url')
if (JSON.stringify(manifest.dna?.compatible_adapters ?? []) !== JSON.stringify(['tsa-codex-1', 'tsa-claude-1', 'tsa-antigravity-1'])) errors.push('dna.compatible_adapters')
// Decisao do Cadu (25/09/2026): no Mac so entra a arquitetura da politica (arm64).
const macArchs = policy.macos?.architectures ?? []
for (const a of manifest.artifacts ?? []) {
  if (a.platform === 'darwin' && !macArchs.includes(a.architecture)) errors.push(`darwin ${a.architecture} (${a.filename}) fora da politica`)
}
if (manifest.state === 'PUBLISHED' && (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0)) errors.push('published artifacts')
if (errors.length) { console.error(`Invalid TSA release manifest: ${errors.join(', ')}`); process.exit(1) }
console.log(`TSA manifest valid: ${manifestPath}`)
