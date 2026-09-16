import { readdir } from 'node:fs/promises'
import { join } from 'node:path'

/** Recursively lists file paths under `dir` (a missing dir yields an empty list). */
export async function walkFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
  const files = []
  for (const entry of entries) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) files.push(...await walkFiles(full))
    else if (entry.isFile()) files.push(full)
  }
  return files
}
