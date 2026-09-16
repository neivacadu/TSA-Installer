import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { walkFiles } from './dist-artifact-walk.mjs'

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
if (JSON.stringify(manifest.dna?.compatible_adapters ?? []) !== JSON.stringify(['tsa-codex-1', 'tsa-claude-1'])) errors.push('dna.compatible_adapters')
if (manifest.state === 'PUBLISHED' && (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0)) errors.push('published artifacts')

// Recalcula o SHA-512 de cada artefato listado contra os arquivos reais do diretorio de distribuicao.
// Um manifesto DRAFT sem artefatos (artifacts: []) nao aciona esta checagem.
if (Array.isArray(manifest.artifacts) && manifest.artifacts.length > 0) {
  const distDir = resolve(process.env.TSA_DIST_DIR ?? 'artifacts')
  const filesByName = new Map()
  for (const file of await walkFiles(distDir)) filesByName.set(file.split(/[\\/]/).pop(), file)
  for (const artifact of manifest.artifacts) {
    const filename = artifact?.filename
    if (!filename) { errors.push('artifact.filename missing'); continue }
    const filePath = filesByName.get(filename)
    if (!filePath) { errors.push(`artifact missing on disk: ${filename}`); continue }
    const bytes = await readFile(filePath)
    if (typeof artifact.bytes === 'number' && bytes.length !== artifact.bytes) errors.push(`artifact size mismatch: ${filename}`)
    const actualSha512 = createHash('sha512').update(bytes).digest('hex')
    if (actualSha512 !== String(artifact.sha512 ?? '').toLowerCase()) errors.push(`artifact sha512 mismatch: ${filename}`)
  }
}

if (errors.length) { console.error(`Invalid TSA release manifest: ${errors.join(', ')}`); process.exit(1) }
console.log(`TSA manifest valid: ${manifestPath}`)
