import { createHash } from 'node:crypto'
import { readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'

const dist = resolve(process.env.TSA_DIST_DIR ?? 'artifacts')
const policy = JSON.parse(await readFile(resolve('config/release-policy.json'), 'utf8'))
async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
  const files = []
  for (const entry of entries) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) files.push(...await walk(full))
    else if (entry.isFile()) files.push(full)
  }
  return files
}
const artifacts = []
for (const file of await walk(dist)) {
  const filename = file.split(/[\\/]/).pop()
  const info = await stat(file)
  const isMac = /^tsa-macos-(arm64|x64|universal)\.(dmg|zip)$/.test(filename)
  const isWindows = /^tsa-windows-x64\.exe$/.test(filename) || /^TSA.*setup.*\.exe$/i.test(filename)
  if (!isMac && !isWindows) continue
  const bytes = await readFile(file)
  const platform = isMac ? 'darwin' : 'win32'
  const architecture = isMac ? filename.match(/^tsa-macos-(arm64|x64|universal)/)[1] : 'x64'
  const kind = isMac ? filename.endsWith('.dmg') ? 'dmg' : 'zip' : 'nsis'
  artifacts.push({ platform, architecture, kind, filename, url: `https://github.com/neivacadu/TSA-Installer/releases/download/${process.env.GITHUB_REF_NAME ?? 'draft'}/${filename}`, sha512: createHash('sha512').update(bytes).digest('hex'), bytes: info.size })
}
const output = { schema_version: 'tsa.distribution.release/v1', state: process.env.TSA_RELEASE_STATE ?? 'DRAFT', product: { name: 'TSA', app_id: policy.appId }, release: { version: process.env.TSA_RELEASE_VERSION ?? '0.0.0', commit: process.env.TSA_APP_COMMIT ?? '0000000000000000000000000000000000000000', channel: process.env.TSA_RELEASE_CHANNEL ?? 'adhoc', created_at: new Date().toISOString() }, dna: { source_repository: `https://github.com/${policy.dnaRepository}`, approved_commit: policy.dnaApprovedCommit, release_version: policy.dnaReleaseVersion, manifest_url: policy.dnaManifestUrl, compatible_adapters: ['tsa-codex-1', 'tsa-claude-1'] }, artifacts }
delete output.artifacts.source
await writeFile(resolve('manifests/tsa-release.json'), `${JSON.stringify(output, null, 2)}\n`)
console.log(`Generated manifest with ${artifacts.length} artifact(s)`)
