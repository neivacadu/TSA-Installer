// Gera, para scripts/test-instalartsa.sh, manifestos assinados por uma chave SÓ de teste (a
// privada some no fim do processo) com o canônico do manifesto.mjs do app, fonte única do JSON
// canônico (C1). Nunca usa as chaves reais.
//   node assinar-teste.mjs <manifesto.mjs> <pasta> <sha256 do DMG> <bytes do DMG> <build_id>
// Grava em <pasta>: chaves.json, valido.json, adulterado.json e os 3 vetores de leitura estrita
// do contrato §7.3, regra 5 (chave repetida, bytes 225552193.0 e 2.25552193e8), com assinatura
// válida sobre o canônico de JSON.parse.
import { generateKeyPairSync, sign } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [manifestoMjs, pasta, sha, bytes, buildId] = process.argv.slice(2)
const { hashManifesto } = await import(pathToFileURL(manifestoMjs).href)
const { publicKey, privateKey } = generateKeyPairSync('ed25519')
const KEY = 'tsa-teste-wo18'
writeFileSync(path.join(pasta, 'chaves.json'),
  JSON.stringify({ [KEY]: publicKey.export({ type: 'spki', format: 'pem' }) }, null, 2) + '\n')

const assinar = (m) => {
  const semAssinatura = { ...m }
  delete semAssinatura.assinatura
  const hash = hashManifesto(semAssinatura)
  return { ...semAssinatura, assinatura: sign(null, Buffer.from(hash, 'ascii'), privateKey).toString('base64') }
}
const base = (artefatoBytes, artefatoSha) => ({
  schema: 'tsa.app.release/v1', produto: 'TSA', app_id: 'com.trafegosa.orca-tsa', versao: '0.5.0',
  build_id: buildId, versao_orca_base: '1.4.197', plataforma: 'darwin', arquitetura: 'arm64',
  artefato: { nome: 'tsa-macos-arm64.dmg', sha256: artefatoSha, bytes: artefatoBytes, url: `/v1/app/artefatos/${artefatoSha}` },
  dna_embutido: '1.0.21', notas: '', publicado_em: '2026-10-02T19:17:00Z', key_id: KEY
})
const gravar = (nome, texto) => writeFileSync(path.join(pasta, nome), texto)

const valido = assinar(base(Number(bytes), sha))
gravar('valido.json', JSON.stringify(valido))
gravar('adulterado.json', JSON.stringify({ ...valido, notas: 'x' }))

// Os 3 vetores de leitura estrita: o texto é diferente, o canônico (de JSON.parse) é o mesmo.
const v = assinar(base(225552193, sha))
const texto = JSON.stringify(v)
gravar('estrito-chave-repetida.json', texto.replace('{"schema":', '{"schema":"tsa.app.release/v0","schema":'))
gravar('estrito-bytes-ponto.json', texto.replace('"bytes":225552193', '"bytes":225552193.0'))
gravar('estrito-bytes-expoente.json', texto.replace('"bytes":225552193', '"bytes":2.25552193e8'))
