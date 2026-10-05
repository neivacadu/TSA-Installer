#!/bin/bash
# Instalador do TSA pelo painel (macOS) — INSTALAR-F2-CONTRATO v2.0, seção 7.
#   curl -fsSL https://ace.caduneiva.com/apptsa/install.sh | bash
# O comando é o mesmo para todos: o convite é pedido aqui, sem eco, e nunca entra no comando.
# Casos (seção 7.4):
#   A  máquina nova: valida o convite, pergunta o setor, confere a assinatura do manifesto,
#      baixa, confere SHA-256 e o DMG, instala, entrega o convite ao app e abre o TSA.
#   B1 já cadastrada, com app: roda o agendador com --agora.
#   B2 com app e sem cadastro (o time de hoje): para sem mudar nada (F20).
#   C  cadastrada, sem app: reinstala com a credencial de atualização do Chaves.
# Quem cadastra é o app (F14). Este script nunca troca um app que já existe.
# Opções: --perfil <id> (avançado; pula a pergunta do setor) e --sem-agendador.
# Tudo fica em funções e só roda na chamada de main na última linha: com curl | bash, um
# download cortado no meio não executa pela metade.
set -euo pipefail

TSA_SCRIPT_VERSAO="2026.10.02.1"

# Ganchos do teste (scripts/test-instalartsa.sh). Em uso normal ficam no padrão.
PAINEL_API="${TSA_PAINEL_API:-https://ace.caduneiva.com/apptsa/api}"
APP_DEST="${TSA_APP_DEST:-/Applications}"
TTY_DEV="${TSA_TTY-/dev/tty}"
CURL="${TSA_CURL:-/usr/bin/curl}"
HDIUTIL="${TSA_HDIUTIL:-/usr/bin/hdiutil}"
CODESIGN="${TSA_CODESIGN:-/usr/bin/codesign}"
DITTO="${TSA_DITTO:-/usr/bin/ditto}"
XATTR="${TSA_XATTR:-/usr/bin/xattr}"
OPEN="${TSA_OPEN:-/usr/bin/open}"
SECURITY="${TSA_SECURITY:-/usr/bin/security}"
KEYCHAIN="${TSA_KEYCHAIN:-}"   # vazio = chaveiro padrão do usuário
PREREQS_URL="${TSA_PREREQS_URL:-https://neivacadu.github.io/TSA-Installer/install.sh}"
OSASCRIPT=/usr/bin/osascript
PLUTIL=/usr/bin/plutil
SHASUM=/usr/bin/shasum

APP_ID="com.trafegosa.orca-tsa"
APP="$APP_DEST/TSA.app"
NOVO="$APP_DEST/.TSA-novo.app"
TSA="$HOME/Library/Application Support/TSA"
LOG_DIR="$HOME/Library/Logs/TSA"
LOCK="$LOG_DIR/.atualizar-aqui.lock"
LOCK_PORTA="$LOG_DIR/.atualizar-aqui.lock.porta"
ATUALIZADOR="$TSA/atualizador/atualizar.sh"
ESTADO="$TSA/atualizacao/estado.json"
INSTALACAO="$TSA/atualizador/instalacao.json"
SEM_AGENDADOR="$TSA/atualizador/sem-agendador"
PERFIL_JSON="$TSA/perfil.json"
RE_CONVITE='^[A-Za-z0-9_-]{43}$'
RE_UUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
PERFIS="trafego audiovisual copy-criativos cs-operacional gestao"
FRASE_FALHA="A versão baixada não passou na conferência. Nada foi instalado. Fale com o Cadu."

TMP=""
MOUNT=""
TRAVA=0
PORTA=0
CONVITE=""
PERFIL=""
SEM_AGENDADOR_OPC=0

say(){ printf '\033[0;36m%s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
die(){ printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

cleanup(){
  CONVITE=""
  if [ -n "$MOUNT" ]; then "$HDIUTIL" detach "$MOUNT" >/dev/null 2>&1 || true; fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  if [ "$PORTA" = 1 ] && [ "$(cat "$LOCK_PORTA/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_PORTA"; fi
  if [ "$TRAVA" = 1 ] && [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------- JavaScript (osascript)
# Leitor estrito de JSON, comum ao verificador e ao leitor de respostas: chave repetida,
# fração, expoente, sinal e zero à esquerda reprovam (contrato §7.3, regra 3). Só o leitor de
# respostas e de arquivos locais aceita true, false, null e lista (com extras); o verificador,
# nenhum deles. Manifesto extraído de uma resposta volta ao verificador, que o lê de novo.
js_json(){ cat <<'JS'
ObjC.import('Foundation')
function lerTexto(caminho) {
  const dados = $.NSData.dataWithContentsOfFile(caminho)
  if (dados.isNil()) throw new Error('ilegivel')
  const texto = $.NSString.alloc.initWithDataEncoding(dados, $.NSUTF8StringEncoding)
  if (texto.isNil()) throw new Error('utf8')
  return ObjC.unwrap(texto)
}
function lerJson(t, extras) {
  let i = 0
  const ws = () => { while (i < t.length && ' \t\n\r'.indexOf(t[i]) >= 0) i++ }
  const falha = () => { throw new Error('json') }
  const SIMPLES = { '"': '"', '\\': '\\', '/': '/', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t' }
  function texto() {
    if (t[i] !== '"') falha()
    i++
    let s = ''
    for (;;) {
      if (i >= t.length) falha()
      const c = t[i]
      if (c === '"') { i++; return s }
      if (t.charCodeAt(i) < 0x20) falha()
      if (c !== '\\') { s += c; i++; continue }
      const e = t[i + 1]
      i += 2
      if (Object.prototype.hasOwnProperty.call(SIMPLES, e)) { s += SIMPLES[e]; continue }
      if (e !== 'u') falha()
      const h = t.slice(i, i + 4)
      if (!/^[0-9a-fA-F]{4}$/.test(h)) falha()
      s += String.fromCharCode(parseInt(h, 16))
      i += 4
    }
  }
  function valor() {
    ws()
    const c = t[i]
    if (c === '{') {
      i++
      const o = Object.create(null)
      ws()
      if (t[i] === '}') { i++; return o }
      for (;;) {
        ws()
        const k = texto()
        if (Object.prototype.hasOwnProperty.call(o, k)) falha()
        ws()
        if (t[i] !== ':') falha()
        i++
        o[k] = valor()
        ws()
        if (t[i] === ',') { i++; continue }
        if (t[i] === '}') { i++; return o }
        falha()
      }
    }
    if (c === '"') return texto()
    if (extras && c === '[') {
      i++
      const l = []
      ws()
      if (t[i] === ']') { i++; return l }
      for (;;) {
        l.push(valor())
        ws()
        if (t[i] === ',') { i++; continue }
        if (t[i] === ']') { i++; return l }
        falha()
      }
    }
    if (extras) {
      for (const [p, v] of [['true', true], ['false', false], ['null', null]]) {
        if (t.startsWith(p, i)) { i += p.length; return v }
      }
    }
    const m = /^(0|[1-9][0-9]*)/.exec(t.slice(i, i + 40))
    if (!m) falha()
    const depois = t[i + m[0].length]
    if (depois === '.' || depois === 'e' || depois === 'E') falha()
    const n = Number(m[0])
    if (!Number.isSafeInteger(n)) falha()
    i += m[0].length
    return n
  }
  const v = valor()
  ws()
  if (i !== t.length) falha()
  return v
}
const objeto = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
JS
}

# Verificador da primeira instalação (seção 7.3). Só tem o modo `verificar`.
js_verificador(){ cat <<'JS'
const temCampo = (o, k) => Object.prototype.hasOwnProperty.call(o, k)
const RE_CONTROLE = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/
const RE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/
const textoCanonico = (s) => !RE_CONTROLE.test(s) && !RE_SURROGATE.test(s)
function canonico(v) {
  if (typeof v === 'string') {
    if (!textoCanonico(v)) throw new Error('texto')
    return JSON.stringify(v)
  }
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v) || v < 0 || Object.is(v, -0)) throw new Error('numero')
    return String(v)
  }
  if (objeto(v)) {
    return '{' + Object.keys(v).sort().map((k) => {
      if (!/^[\x20-\x7e]+$/.test(k)) throw new Error('chave')
      return JSON.stringify(k) + ':' + canonico(v[k])
    }).join(',') + '}'
  }
  throw new Error('tipo')
}
const CAMPOS = ['schema', 'produto', 'app_id', 'versao', 'build_id', 'versao_orca_base', 'plataforma',
  'arquitetura', 'artefato', 'dna_embutido', 'notas', 'publicado_em', 'key_id', 'assinatura']
const CAMPOS_ARTEFATO = ['nome', 'sha256', 'bytes', 'url']
const COMBINACOES = { 'darwin/arm64': 'tsa-macos-arm64.dmg' }
const RE_KEY_ID = /^[a-z0-9][a-z0-9-]{2,62}$/
const ALFABETO = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function dataHoraExiste(a, m, d, h, mi, s) {
  if (h > 23 || mi > 59 || s > 59) return false
  const t = new Date(0)
  t.setUTCFullYear(a, m - 1, d)
  return t.getUTCFullYear() === a && t.getUTCMonth() === m - 1 && t.getUTCDate() === d
}
const ehTexto = (v) => typeof v === 'string'
function buildId(v) {
  const r = ehTexto(v) && /^[0-9a-f]{7,12}\.([0-9]{8})T([0-9]{6})Z$/.exec(v)
  if (!r) return false
  const [d, h] = [r[1], r[2]]
  return dataHoraExiste(+d.slice(0, 4), +d.slice(4, 6), +d.slice(6, 8), +h.slice(0, 2), +h.slice(2, 4), +h.slice(4, 6))
}
function publicadoEm(v) {
  const r = ehTexto(v) && /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/.exec(v)
  return !!r && dataHoraExiste(...r.slice(1, 7).map(Number))
}
// Base64 canônico: os bits que sobram no último caractere têm de ser zero.
const assinaturaFormato = (v) => ehTexto(v) && /^[A-Za-z0-9+/]{86}==$/.test(v) && (ALFABETO.indexOf(v[85]) & 15) === 0
const REGRAS = {
  schema: (v) => v === 'tsa.app.release/v1',
  produto: (v) => v === 'TSA',
  app_id: (v) => v === 'com.trafegosa.orca-tsa',
  versao: (v) => ehTexto(v) && /^(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,5})$/.test(v),
  build_id: buildId,
  versao_orca_base: (v) => ehTexto(v) && v.length <= 60 && /^\d{1,4}\.\d{1,4}\.\d{1,6}(-[0-9A-Za-z.]{1,40})?$/.test(v),
  plataforma: (v) => v === 'darwin' || v === 'win32',
  arquitetura: (v) => v === 'arm64' || v === 'x64',
  dna_embutido: (v) => ehTexto(v) && /^\d{1,4}\.\d{1,4}\.\d{1,6}$/.test(v),
  notas: (v) => ehTexto(v) && Array.from(v).length <= 500 && textoCanonico(v),
  publicado_em: publicadoEm,
  key_id: (v) => ehTexto(v) && RE_KEY_ID.test(v),
  assinatura: assinaturaFormato
}
function validar(m) {
  if (!objeto(m)) return '(raiz)'
  for (const k of Object.keys(m)) if (CAMPOS.indexOf(k) < 0) return k
  for (const c of CAMPOS) {
    if (!temCampo(m, c)) return c
    if (c !== 'artefato' && !REGRAS[c](m[c])) return c
  }
  const a = m.artefato
  if (!objeto(a)) return 'artefato'
  for (const k of Object.keys(a)) if (CAMPOS_ARTEFATO.indexOf(k) < 0) return 'artefato.' + k
  for (const c of CAMPOS_ARTEFATO) if (!temCampo(a, c)) return 'artefato.' + c
  const nome = COMBINACOES[m.plataforma + '/' + m.arquitetura]
  if (!nome) return 'arquitetura'
  if (a.nome !== nome) return 'artefato.nome'
  if (!ehTexto(a.sha256) || !/^[0-9a-f]{64}$/.test(a.sha256)) return 'artefato.sha256'
  if (!Number.isSafeInteger(a.bytes) || a.bytes < 1 || a.bytes > 629145600) return 'artefato.bytes'
  if (a.url !== '/v1/app/artefatos/' + a.sha256) return 'artefato.url'
  return null
}
function utf8(texto) {
  const s = []
  for (let i = 0; i < texto.length; i++) {
    let c = texto.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff) {
      const b = texto.charCodeAt(i + 1)
      if (!(b >= 0xdc00 && b <= 0xdfff)) throw new Error('surrogate')
      c = 0x10000 + ((c - 0xd800) << 10) + (b - 0xdc00)
      i++
    } else if (c >= 0xdc00 && c <= 0xdfff) throw new Error('surrogate')
    if (c < 0x80) s.push(c)
    else if (c < 0x800) s.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) s.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else s.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  return s
}
function base64(t) {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(t) || t.length % 4 !== 0) throw new Error('base64')
  const s = []
  for (let i = 0; i < t.length; i += 4) {
    const n = [0, 1, 2, 3].map((j) => (t[i + j] === '=' ? 0 : ALFABETO.indexOf(t[i + j])))
    const v = (n[0] << 18) | (n[1] << 12) | (n[2] << 6) | n[3]
    s.push((v >> 16) & 255)
    if (t[i + 2] !== '=') s.push((v >> 8) & 255)
    if (t[i + 3] !== '=') s.push(v & 255)
  }
  return s
}
const primo = (n) => { for (let i = 2; i * i <= n; i++) if (n % i === 0) return false; return true }
function sha256(bytes) {
  const K = [], H = []
  for (let n = 2; K.length < 64; n++) if (primo(n)) K.push((Math.cbrt(n) % 1) * 4294967296 | 0)
  for (let n = 2; H.length < 8; n++) if (primo(n)) H.push((Math.sqrt(n) % 1) * 4294967296 | 0)
  const m = bytes.slice(), bits = bytes.length * 8
  m.push(0x80)
  while (m.length % 64 !== 56) m.push(0)
  const alto = Math.floor(bits / 4294967296), baixo = bits >>> 0
  for (let i = 3; i >= 0; i--) m.push((alto >>> (i * 8)) & 255)
  for (let i = 3; i >= 0; i--) m.push((baixo >>> (i * 8)) & 255)
  const r = (x, n) => (x >>> n) | (x << (32 - n))
  const w = new Array(64)
  for (let o = 0; o < m.length; o += 64) {
    for (let i = 0; i < 16; i++) w[i] = (m[o + 4 * i] << 24) | (m[o + 4 * i + 1] << 16) | (m[o + 4 * i + 2] << 8) | m[o + 4 * i + 3]
    for (let i = 16; i < 64; i++) {
      const s0 = r(w[i - 15], 7) ^ r(w[i - 15], 18) ^ (w[i - 15] >>> 3)
      const s1 = r(w[i - 2], 17) ^ r(w[i - 2], 19) ^ (w[i - 2] >>> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0
    }
    let [a, b, c, d, e, f, g, h] = H
    for (let i = 0; i < 64; i++) {
      const t1 = (h + (r(e, 6) ^ r(e, 11) ^ r(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0
      const t2 = ((r(a, 2) ^ r(a, 13) ^ r(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0
    }
    ;[a, b, c, d, e, f, g, h].forEach((v, i) => { H[i] = (H[i] + v) | 0 })
  }
  return H.map((v) => (v >>> 0).toString(16).padStart(8, '0')).join('')
}
function sha512(bytes) {
  const M = (1n << 64n) - 1n
  const raiz = (n, k) => {
    let x = 1n << BigInt(Math.ceil(n.toString(2).length / k))
    for (;;) { const y = ((BigInt(k) - 1n) * x + n / x ** (BigInt(k) - 1n)) / BigInt(k); if (y >= x) return x; x = y }
  }
  const K = [], H = []
  for (let n = 2; K.length < 80; n++) if (primo(n)) K.push(raiz(BigInt(n) << 192n, 3) & M)
  for (let n = 2; H.length < 8; n++) if (primo(n)) H.push(raiz(BigInt(n) << 128n, 2) & M)
  const m = bytes.slice(), bits = BigInt(bytes.length) * 8n
  m.push(0x80)
  while (m.length % 128 !== 112) m.push(0)
  for (let i = 15; i >= 0; i--) m.push(Number((bits >> BigInt(i * 8)) & 255n))
  const r = (x, n) => ((x >> BigInt(n)) | (x << BigInt(64 - n))) & M
  const w = new Array(80)
  for (let o = 0; o < m.length; o += 128) {
    for (let i = 0; i < 16; i++) { let v = 0n; for (let j = 0; j < 8; j++) v = (v << 8n) | BigInt(m[o + 8 * i + j]); w[i] = v }
    for (let i = 16; i < 80; i++) {
      const s0 = r(w[i - 15], 1) ^ r(w[i - 15], 8) ^ (w[i - 15] >> 7n)
      const s1 = r(w[i - 2], 19) ^ r(w[i - 2], 61) ^ (w[i - 2] >> 6n)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M
    }
    let [a, b, c, d, e, f, g, h] = H
    for (let i = 0; i < 80; i++) {
      const t1 = (h + (r(e, 14) ^ r(e, 18) ^ r(e, 41)) + ((e & f) ^ (~e & M & g)) + K[i] + w[i]) & M
      const t2 = ((r(a, 28) ^ r(a, 34) ^ r(a, 39)) + ((a & b) ^ (a & c) ^ (b & c))) & M
      h = g; g = f; f = e; e = (d + t1) & M; d = c; c = b; b = a; a = (t1 + t2) & M
    }
    ;[a, b, c, d, e, f, g, h].forEach((v, i) => { H[i] = (H[i] + v) & M })
  }
  const s = []
  for (const v of H) for (let j = 7; j >= 0; j--) s.push(Number((v >> BigInt(j * 8)) & 255n))
  return s
}
// Ed25519, RFC 8032 seção 5.1.7: S menor que L; R recalculado como [S]B − [k]A e comparado por bytes.
const P = (1n << 255n) - 19n
const L = (1n << 252n) + 27742317777372353535851937790883648493n
const mod = (a) => ((a % P) + P) % P
const pot = (b, e) => { let r = 1n; b = mod(b); while (e > 0n) { if (e & 1n) r = (r * b) % P; b = (b * b) % P; e >>= 1n } return r }
const inv = (a) => pot(a, P - 2n)
const D = mod(-121665n * inv(121666n))
const RAIZ_M1 = pot(2n, (P - 1n) / 4n)
const le = (bytes) => bytes.reduceRight((acc, b) => (acc << 8n) | BigInt(b), 0n)
function ponto(bytes) {
  if (bytes.length !== 32) return null
  const sinal = BigInt(bytes[31] >> 7)
  const y = le(bytes) & ((1n << 255n) - 1n)
  if (y >= P) return null
  const y2 = (y * y) % P
  const x2 = mod((y2 - 1n) * inv(D * y2 + 1n))
  let x = pot(x2, (P + 3n) / 8n)
  if (mod(x * x - x2) !== 0n) x = (x * RAIZ_M1) % P
  if (mod(x * x - x2) !== 0n) return null
  if (x === 0n && sinal === 1n) return null
  if ((x & 1n) !== sinal) x = P - x
  return [x, y, 1n, (x * y) % P]
}
function soma(p, q) {
  const a = mod((p[1] - p[0]) * (q[1] - q[0])), b = mod((p[1] + p[0]) * (q[1] + q[0]))
  const c = mod(2n * p[3] * q[3] * D), d = mod(2n * p[2] * q[2])
  const e = b - a, f = d - c, g = d + c, h = b + a
  return [mod(e * f), mod(g * h), mod(f * g), mod(e * h)]
}
function vezes(k, p) {
  let r = [0n, 1n, 1n, 0n]
  while (k > 0n) { if (k & 1n) r = soma(r, p); p = soma(p, p); k >>= 1n }
  return r
}
function codificar(p) {
  const zi = inv(p[2]), x = mod(p[0] * zi)
  let y = mod(p[1] * zi) | ((x & 1n) << 255n)
  const s = []
  for (let i = 0; i < 32; i++) { s.push(Number(y & 255n)); y >>= 8n }
  return s
}
const BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202n
const BY = 46316835694926478169428394003475163141307993866256225615783033603165251855960n
const BASE = [BX, BY, 1n, (BX * BY) % P]
function ed25519(chave, mensagem, assinatura) {
  if (chave.length !== 32 || assinatura.length !== 64) return false
  const A = ponto(chave)
  if (!A) return false
  const R = assinatura.slice(0, 32), S = le(assinatura.slice(32))
  if (S >= L) return false
  const k = le(sha512(R.concat(chave, mensagem))) % L
  const menosA = [mod(-A[0]), A[1], A[2], mod(-A[3])]
  const Rcalc = codificar(soma(vezes(S, BASE), vezes(k, menosA)))
  return Rcalc.every((b, i) => b === R[i])
}
// PEM SPKI Ed25519 exato (44 bytes DER, prefixo do OID 1.3.101.112), base64 canônico.
const PREFIXO = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
function chaveDoPem(pem) {
  const m = ehTexto(pem) && /^-----BEGIN PUBLIC KEY-----\n([A-Za-z0-9+/]{59}=)\n-----END PUBLIC KEY-----\n$/.exec(pem)
  if (!m || (ALFABETO.indexOf(m[1][58]) & 3) !== 0) return null
  const der = base64(m[1])
  if (der.length !== 44 || !PREFIXO.every((b, i) => der[i] === b)) return null
  return der.slice(12)
}
// O arquivo de chaves inteiro tem de estar no formato; uma entrada irregular reprova todas.
function chaveConfiavel(chaves, keyId) {
  if (!objeto(chaves) || Object.keys(chaves).length === 0) return null
  let achada = null
  for (const id of Object.keys(chaves)) {
    if (!RE_KEY_ID.test(id)) return null
    const c = chaveDoPem(chaves[id])
    if (!c) return null
    if (id === keyId) achada = c
  }
  return achada
}
function verificar(textoManifesto, textoChaves) {
  let m
  try { m = lerJson(textoManifesto, false) } catch (e) { return { ok: false, motivo: 'manifesto_invalido', campo: '(raiz)' } }
  const campo = validar(m)
  if (campo) return { ok: false, motivo: 'manifesto_invalido', campo }
  let chaves = null
  try { chaves = lerJson(textoChaves, false) } catch (e) { chaves = null }
  const chave = chaveConfiavel(chaves, m.key_id)
  if (!chave) return { ok: false, motivo: 'chave_desconhecida' }
  const resto = {}
  for (const k of Object.keys(m)) if (k !== 'assinatura') resto[k] = m[k]
  let hash
  try { hash = sha256(utf8(canonico(resto))) } catch (e) { return { ok: false, motivo: 'manifesto_invalido', campo: '(raiz)' } }
  if (!ed25519(chave, utf8(hash), base64(m.assinatura))) return { ok: false, motivo: 'assinatura_invalida' }
  return { ok: true, hash, key_id: m.key_id }
}
function run(argv) {
  if (argv[0] !== 'verificar' || argv.length !== 3) return JSON.stringify({ ok: false, motivo: 'uso' })
  let mt, ct
  try { mt = lerTexto(argv[1]) } catch (e) { return JSON.stringify({ ok: false, motivo: 'manifesto_invalido', campo: '(raiz)' }) }
  try { ct = lerTexto(argv[2]) } catch (e) { return JSON.stringify({ ok: false, motivo: 'chave_desconhecida' }) }
  try { return JSON.stringify(verificar(mt, ct)) } catch (e) { return JSON.stringify({ ok: false, motivo: 'manifesto_invalido', campo: '(raiz)' }) }
}
JS
}

# Leitor de respostas e arquivos locais, com o mesmo leitor estrito.
#   campo <arquivo> <a.b.c>        imprime texto, inteiro, true, false, null ou "objeto"; falta: erro
#   objeto <arquivo> <a.b> <saida> grava o objeto em JSON
js_leitor(){ cat <<'JS'
function achar(arquivo, caminho) {
  let v = lerJson(lerTexto(arquivo), true)
  for (const parte of caminho.split('.')) {
    if (!objeto(v) || !Object.prototype.hasOwnProperty.call(v, parte)) throw new Error('ausente')
    v = v[parte]
  }
  return v
}
function run(argv) {
  const v = achar(argv[1], argv[2])
  if (argv[0] === 'campo') {
    if (typeof v === 'string') {
      if (/[\n\r]/.test(v)) throw new Error('quebra')
      return v
    }
    if (objeto(v)) return 'objeto'
    if (Array.isArray(v)) return 'lista'
    return String(v)
  }
  if (argv[0] === 'objeto') {
    if (!objeto(v)) throw new Error('nao_objeto')
    if (!$(JSON.stringify(v)).writeToFileAtomicallyEncodingError(argv[3], true, $.NSUTF8StringEncoding, null)) throw new Error('gravar')
    return ''
  }
  throw new Error('uso')
}
JS
}

# Chaves confiáveis, iguais byte a byte a tsa-app/resources/tsa/app-trusted-keys.json
# (seção 7.3, regra 2; o teste compara os dois). O script não busca chave em lugar nenhum.
chaves_confiaveis(){ cat <<'JSON'
{
  "tsa-cadu-app-release-v1": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAlERMsGnZR8BgHewu1esGEdYdBB4V256mXQ6VEW5nNZQ=\n-----END PUBLIC KEY-----\n",
  "tsa-cadu-app-release-v2": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAOgeeJOJQF8+rLmKEWNQ77aRx4poq1WyggwfGmsknD/Q=\n-----END PUBLIC KEY-----\n"
}
JSON
}

preparar_js(){
  { js_json; js_verificador; } >"$TMP/verificador.js"
  { js_json; js_leitor; } >"$TMP/leitor.js"
  chaves_confiaveis >"$TMP/chaves.json"
  chmod 600 "$TMP/verificador.js" "$TMP/leitor.js" "$TMP/chaves.json"
}

# campo <arquivo> <caminho>: valor de um campo JSON; falha se faltar ou se o JSON for irregular.
campo(){ "$OSASCRIPT" -l JavaScript "$TMP/leitor.js" campo "$1" "$2" 2>/dev/null; }

# ---------------------------------------------------------------- HTTP
# Todo pedido vai por `curl --config -`: URL, cabeçalhos e corpo com segredo saem pela entrada
# padrão, nunca em argumento (seção 7.6). O -q vem primeiro: sem ele o curl lê o ~/.curlrc, que
# pode ligar trace e gravar o segredo em arquivo. Imprime "<código HTTP> <retorno do curl>";
# corpo em $2.
#   http <url> <saida> [<corpo JSON>] [<cabeçalho com segredo>] [continuar]
http(){
  local url="$1" saida="$2" corpo="${3:-}" cab="${4:-}" cont="${5:-}" cfg
  cfg="url = \"$url\""$'\n'"output = \"$saida\""$'\n'"silent"$'\n'"show-error"$'\n'
  cfg+="max-time = 1800"$'\n'"connect-timeout = 20"$'\n'"write-out = \"%{http_code}\""$'\n'
  [ -n "$corpo" ] && cfg+="header = \"Content-Type: application/json\""$'\n'"data = \"${corpo//\"/\\\"}\""$'\n'
  [ -n "$cab" ] && cfg+="header = \"$cab\""$'\n'
  [ -n "$cont" ] && cfg+="continue-at = \"-\""$'\n'
  local codigo rc=0
  codigo="$(printf '%s' "$cfg" | "$CURL" -q --config - 2>/dev/null)" || rc=$?
  printf '%s %s' "${codigo:-000}" "$rc"
}
# Só o código HTTP de um pedido curto.
http_codigo(){ local r; r="$(http "$@")"; printf '%s' "${r%% *}"; }

# ---------------------------------------------------------------- convite e setor
tem_tty(){ [ -n "$TTY_DEV" ] && { : <"$TTY_DEV"; } 2>/dev/null; }
# O terminal abre uma vez só, no descritor 3: as perguntas leem em sequência dele.
abrir_tty(){
  [ "${TTY_ABERTO:-0}" = 1 ] && return 0
  tem_tty || die "Este instalador precisa de um terminal para perguntar. Rode no app Terminal."
  exec 3<"$TTY_DEV"
  TTY_ABERTO=1
}

pedir_convite(){
  local tentativa codigo c
  for tentativa in 1 2 3; do
    printf 'Cole o convite que o Cadu mandou e aperte Enter (não aparece na tela): ' >&2
    IFS= read -rs c <&3 || c=""
    printf '\n' >&2
    if [[ ! "$c" =~ $RE_CONVITE ]]; then
      printf '  O convite tem 43 caracteres. Confira e cole de novo.\n' >&2
      continue
    fi
    codigo="$(http_codigo "$PAINEL_API/convite/validar" "$TMP/convite.json" "{\"convite\":\"$c\"}")"
    case "$codigo" in
      200)
        [ "$(campo "$TMP/convite.json" valido)" = true ] || die "Resposta estranha da Central. Tente de novo mais tarde."
        CONVITE="$c"
        PERFIL_SUGERIDO="$(campo "$TMP/convite.json" perfil_sugerido || true)"
        ok "Convite válido"
        return 0 ;;
      401) printf '  Convite não reconhecido. Confira e cole de novo.\n' >&2 ;;
      410)
        case "$(campo "$TMP/convite.json" error || true)" in
          convite_usado) die "Este convite já foi usado. Peça outro ao Cadu." ;;
          convite_expirado) die "Este convite venceu. Peça outro ao Cadu." ;;
          *) die "Este convite foi cancelado. Peça outro ao Cadu." ;;
        esac ;;
      429) die "Muitas tentativas. Espere uma hora e rode o comando de novo." ;;
      *) die "Não consegui falar com a Central (código $codigo). Tente de novo em alguns minutos." ;;
    esac
  done
  die "Três tentativas sem convite válido. Peça o convite de novo ao Cadu."
}

perfil_valido(){ local p; for p in $PERFIS; do [ "$1" = "$p" ] && return 0; done; return 1; }

perguntar_setor(){
  local r ids
  if [ -n "$PERFIL" ]; then return 0; fi
  ids=($PERFIS)
  while :; do
    printf '\nQual é o seu setor?\n  1. Tráfego\n  2. Audiovisual\n  3. Copy e Criativos\n  4. CS/operacional\n  5. Gestão\n' >&2
    [ -n "${PERFIL_SUGERIDO:-}" ] && perfil_valido "$PERFIL_SUGERIDO" &&
      printf '(O Cadu sugeriu: %s)\n' "$PERFIL_SUGERIDO" >&2
    printf 'Digite o número e aperte Enter: ' >&2
    IFS= read -r r <&3 || die "Sem resposta do setor. Rode o comando de novo."
    case "$r" in
      [1-5]) PERFIL="${ids[$((r - 1))]}"; return 0 ;;
    esac
    printf '  Escolha um número de 1 a 5.\n' >&2
  done
}

# ---------------------------------------------------------------- manifesto, download, DMG
# Confere assinatura e campos do manifesto já extraído em $TMP/manifesto.json (seção 7.3).
conferir_manifesto(){
  local saida
  saida="$("$OSASCRIPT" -l JavaScript "$TMP/verificador.js" verificar "$TMP/manifesto.json" "$TMP/chaves.json" 2>/dev/null)" ||
    die "$FRASE_FALHA"
  case "$saida" in
    '{"ok":true,'*) ;;
    *) die "$FRASE_FALHA" ;;
  esac
  [ "$(campo "$TMP/manifesto.json" plataforma)" = darwin ] || die "$FRASE_FALHA"
  [ "$(campo "$TMP/manifesto.json" arquitetura)" = arm64 ] || die "$FRASE_FALHA"
  [ "$(campo "$TMP/manifesto.json" app_id)" = "$APP_ID" ] || die "$FRASE_FALHA"
  BUILD_ID="$(campo "$TMP/manifesto.json" build_id)"
  SHA="$(campo "$TMP/manifesto.json" artefato.sha256)"
  BYTES="$(campo "$TMP/manifesto.json" artefato.bytes)"
  VERSAO="$(campo "$TMP/manifesto.json" versao)"
  ok "Assinatura da versão $VERSAO conferida"
}

# Extrai o manifesto da resposta $1 para $TMP/manifesto.json.
extrair_manifesto(){
  "$OSASCRIPT" -l JavaScript "$TMP/leitor.js" objeto "$1" manifesto "$TMP/manifesto.json" >/dev/null 2>&1 ||
    die "$FRASE_FALHA"
}

# Pede o manifesto: caso A pela rota do convite, caso C pela credencial. Grava a resposta em $1.
pedir_manifesto(){
  local saida="$1" codigo
  if [ "$CASO" = A ]; then
    codigo="$(http_codigo "$PAINEL_API/release/nova-instalacao" "$saida" \
      "{\"convite\":\"$CONVITE\",\"plataforma\":\"darwin\",\"arquitetura\":\"arm64\"}")"
  else
    codigo="$(http_codigo "$API/v1/app/release?plataforma=darwin&arquitetura=arm64" "$saida" "" \
      "Authorization: Bearer $(ler_credencial)")"
  fi
  case "$codigo" in
    200) return 0 ;;
    204) die "Ainda não há versão liberada. Fale com o Cadu." ;;
    410) die "O convite deixou de valer. Peça outro ao Cadu." ;;
    401|403) die "A Central não aceitou o acesso desta máquina. Fale com o Cadu." ;;
    429) die "Muitas tentativas. Espere uma hora e rode o comando de novo." ;;
    *) die "Não consegui falar com a Central (código $codigo). Tente de novo em alguns minutos." ;;
  esac
}

baixar(){
  local destino="$TMP/tsa-macos-arm64.dmg" tentativa codigo url cab
  if [ "$CASO" = A ]; then
    url="$PAINEL_API/artefatos/$SHA"; cab="X-TSA-Convite: $CONVITE"
  else
    url="$API/v1/app/artefatos/$SHA"; cab="Authorization: Bearer $(ler_credencial)"
  fi
  say "Baixando o TSA $VERSAO..."
  # Transferência que caiu no meio guarda o parcial e retoma por Range; resposta de erro
  # apaga o arquivo (o corpo do erro não pode virar começo do DMG).
  local r rc
  for tentativa in 1 2 3 4 5; do
    r="$(http "$url" "$destino" "" "$cab" continuar)"; codigo="${r%% *}"; rc="${r##* }"
    case "$codigo" in
      200|206) [ "$rc" = 0 ] && break ;;
      416) [ "$(stat -f %z "$destino" 2>/dev/null || echo 0)" = "$BYTES" ] && break; rm -f "$destino" ;;
      *) rm -f "$destino" ;;
    esac
    [ "$tentativa" = 5 ] && { rm -f "$destino"; die "O download não terminou (código $codigo). Tente de novo em alguns minutos."; }
    sleep "${TSA_ESPERA_DOWNLOAD:-3}"
  done
  say "Conferindo o arquivo..."
  if [ "$(stat -f %z "$destino")" != "$BYTES" ] ||
     [ "$("$SHASUM" -a 256 "$destino" | awk '{print $1}')" != "$SHA" ]; then
    rm -f "$destino"; die "$FRASE_FALHA"
  fi
  ok "Tamanho e SHA-256 conferidos"
  "$HDIUTIL" verify "$destino" >/dev/null 2>&1 || { rm -f "$destino"; die "$FRASE_FALHA"; }
  MOUNT="$("$HDIUTIL" attach "$destino" -nobrowse -readonly </dev/null | awk -F'\t' '$NF ~ "^/" {m=$NF} END{print m}')"
  [ -n "$MOUNT" ] || die "$FRASE_FALHA"
  SRC_APP="$MOUNT/TSA.app"
  [ -d "$SRC_APP" ] || die "$FRASE_FALHA"
  [ "$("$PLUTIL" -extract CFBundleIdentifier raw -o - "$SRC_APP/Contents/Info.plist" 2>/dev/null)" = "$APP_ID" ] ||
    die "$FRASE_FALHA"
  "$CODESIGN" --verify --deep --strict "$SRC_APP" >/dev/null 2>&1 || die "$FRASE_FALHA"
  [ "$(campo "$SRC_APP/Contents/Resources/tsa/tsa-version.json" build_id)" = "$BUILD_ID" ] || die "$FRASE_FALHA"
  ok "Pacote conferido"
}

# ---------------------------------------------------------------- trava compartilhada
# Mesmo protocolo do atualizar-aqui.sh: porta por mkdir, trava por link simbólico para o pid,
# dono morto é retomado, dono vivo recusa (seção 9.2, passo 2).
pegar_trava(){
  local dono
  [ -d "$LOG_DIR" ] || { mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"; }
  # Porta ocupada recusa, viva ou abandonada, como no atualizar-aqui.sh: retomar a porta de outro
  # deixaria dois recuperadores passarem juntos (CX-18-13). O pid dentro dela serve ao diagnóstico.
  mkdir "$LOCK_PORTA" 2>/dev/null || return 1
  PORTA=1
  echo $$ >"$LOCK_PORTA/pid"
  if [ -L "$LOCK" ] || [ -e "$LOCK" ]; then
    dono="$(readlink "$LOCK" 2>/dev/null || cat "$LOCK" 2>/dev/null || true)"
    case "$dono" in ''|*[!0-9]*) soltar_porta; return 1 ;; esac
    if kill -0 "$dono" 2>/dev/null; then soltar_porta; return 1; fi
    rm -rf "$LOCK"
    if [ -L "$LOCK" ] || [ -e "$LOCK" ]; then soltar_porta; return 1; fi
  fi
  if ! ln -s "$$" "$LOCK" 2>/dev/null || [ "$(readlink "$LOCK")" != "$$" ]; then
    soltar_porta; return 1
  fi
  soltar_porta
  TRAVA=1
}
soltar_porta(){ rm -rf "$LOCK_PORTA"; PORTA=0; }
msg_trava(){
  local d
  d="$(cat "$LOCK_PORTA/pid" 2>/dev/null || true)"
  if [ -d "$LOCK_PORTA" ] && { [ -z "$d" ] || ! kill -0 "$d" 2>/dev/null; }; then
    printf 'Uma atualização anterior parou no meio e deixou a trava %s. Se nenhuma atualização estiver rodando, apague essa pasta e rode o comando de novo.' "$LOCK_PORTA"
  else
    printf 'Há outra atualização em andamento. Espere terminar e rode o comando de novo.'
  fi
}
soltar_trava(){
  [ "$TRAVA" = 1 ] && [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"
  TRAVA=0
}

# ---------------------------------------------------------------- instalação (passo 7)
instalar(){
  local de_novo="$TMP/manifesto-2.json"
  # (a) Reconsulta: a release ainda é a mesma (pausa ou troca no meio do download para aqui).
  pedir_manifesto "$TMP/resposta-2.json"
  "$OSASCRIPT" -l JavaScript "$TMP/leitor.js" objeto "$TMP/resposta-2.json" manifesto "$de_novo" >/dev/null 2>&1 ||
    die "A versão mudou durante o download. Rode o comando de novo."
  [ "$(campo "$de_novo" build_id)" = "$BUILD_ID" ] && [ "$(campo "$de_novo" artefato.sha256)" = "$SHA" ] ||
    die "A versão mudou durante o download. Rode o comando de novo."
  # (b) Trava.
  pegar_trava || die "$(msg_trava)"
  [ -w "$APP_DEST" ] || die "Sem permissão para gravar em $APP_DEST. Fale com o Cadu."
  [ -e "$APP" ] && die "Apareceu um TSA em $APP_DEST durante a instalação. Nada foi trocado. Rode o comando de novo."
  # (c) Cópia ao lado, conferida; (d) só então entra no lugar. Não há bundle anterior.
  say "Instalando..."
  rm -rf "$NOVO"
  "$DITTO" "$SRC_APP" "$NOVO" || { rm -rf "$NOVO"; die "Falha ao copiar o app. Nada foi instalado."; }
  "$XATTR" -dr com.apple.quarantine "$NOVO" >/dev/null 2>&1 || true
  "$CODESIGN" --verify --deep --strict "$NOVO" >/dev/null 2>&1 || { rm -rf "$NOVO"; die "$FRASE_FALHA"; }
  [ -e "$APP" ] && { rm -rf "$NOVO"; die "Apareceu um TSA em $APP_DEST durante a instalação. Nada foi trocado."; }
  mv "$NOVO" "$APP" || { rm -rf "$NOVO"; die "Falha ao pôr o app no lugar. Nada foi instalado."; }
  soltar_trava
  ok "TSA $VERSAO instalado em $APP_DEST"
}

# ---------------------------------------------------------------- perfil, agendador, convite
pasta_privada(){ mkdir -p "$1" && chmod 700 "$1"; }

gravar_perfil(){
  pasta_privada "$TSA"
  if [ "$CASO" = C ] && [ -f "$PERFIL_JSON" ]; then return 0; fi
  if [ -z "$PERFIL" ]; then abrir_tty; perguntar_setor; fi
  local tmp="$TSA/.perfil.json.$$"
  (umask 077; printf '{ "perfil": "%s" }\n' "$PERFIL" >"$tmp")
  chmod 600 "$tmp"
  mv "$tmp" "$PERFIL_JSON"
}

marca_agendador(){
  pasta_privada "$TSA"; pasta_privada "$TSA/atualizador"
  if [ "$SEM_AGENDADOR_OPC" = 1 ]; then (umask 077; : >"$SEM_AGENDADOR"); chmod 600 "$SEM_AGENDADOR"
  else rm -f "$SEM_AGENDADOR"; fi
}

# Passo 9: o convite vai ao Chaves pelo `security -i`, com o comando na entrada padrão: o valor
# nunca aparece em argumento de processo (seção 8.6, regra 2; provado na WO-18).
entregar_convite(){
  printf 'add-generic-password -U -s tsa-convite-pendente -a convite -w %s %s\n' "$CONVITE" "$KEYCHAIN" |
    "$SECURITY" -i >/dev/null 2>&1 || die "Não consegui guardar o convite no Chaves. Fale com o Cadu."
  CONVITE=""
}

# ---------------------------------------------------------------- casos
cadastrada(){
  local id api
  [ -f "$INSTALACAO" ] || return 1
  id="$(campo "$INSTALACAO" installation_id)" || return 1
  api="$(campo "$INSTALACAO" api)" || return 1
  [[ "$id" =~ $RE_UUID ]] || return 1
  [[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] || return 1
  "$SECURITY" find-generic-password -s tsa-atualizador -a "$id" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1 || return 1
  ID="$id"; API="$api"
}

# A credencial é lida a cada uso e só passa pela entrada padrão do curl.
ler_credencial(){
  local c
  c="$("$SECURITY" find-generic-password -s tsa-atualizador -a "$ID" -w ${KEYCHAIN:+"$KEYCHAIN"} 2>/dev/null)" || c=""
  # Fora do formato (43 base64url) não entra no config do curl.
  [[ "$c" =~ $RE_CONVITE ]] || { printf 'credencial-invalida'; return 1; }
  printf '%s' "$c"
}

# Troca interrompida: o app pode estar fora do lugar só por isso. Conclui antes de classificar.
troca_pendente(){ [ -f "$ESTADO" ] && [ "$(campo "$ESTADO" troca || true)" = objeto ]; }
retomar_troca(){
  troca_pendente || return 0
  local rc=0 v
  [ -f "$ATUALIZADOR" ] || die "Há uma atualização interrompida. Fale com o Cadu."
  /bin/bash "$ATUALIZADOR" --retomar || rc=$?
  # Depois de uma troca pendente, só segue com o estado lido e "troca": null explícito.
  v="$(campo "$ESTADO" troca)" || v=""
  [ "$rc" = 0 ] && [ "$v" = null ] || die "Há uma atualização interrompida. Fale com o Cadu."
}

caso_b1(){
  marca_agendador
  [ -f "$ATUALIZADOR" ] || die "Abra o TSA uma vez e rode este comando de novo."
  say "O TSA já está instalado e cadastrado. Procurando atualização..."
  local resumo="$LOG_DIR/atualizar-auto-ultimo.json" antes rc=0
  # Só vale o resumo gravado por esta execução: a escrita atômica troca o arquivo (inode,
  # hora ou conteúdo mudam). O mesmo arquivo de antes é resultado velho.
  assinatura_resumo(){ [ -f "$resumo" ] && { stat -f '%i %m %z' "$resumo"; "$SHASUM" -a 256 "$resumo"; } 2>/dev/null; }
  antes="$(assinatura_resumo || true)"
  /bin/bash "$ATUALIZADOR" --agora || rc=$?
  [ "$rc" = 0 ] || die "O atualizador parou com erro ($rc). Fale com o Cadu."
  if [ -f "$resumo" ] && [ "$(assinatura_resumo || true)" != "$antes" ]; then
    printf 'Resultado: %s\n' "$(campo "$resumo" estado || echo desconhecido)"
  else
    die "O atualizador não deixou o resultado desta execução. Fale com o Cadu."
  fi
}

ferramentas_e_abrir(){
  # atalho: na F2 as ferramentas vêm do instalador de hoje (TSA_ONLY_PREREQS=1, mesma fonte do
  # comando do GitHub). Teto: não há grupo por perfil. Saída: WO-25 (F3) troca por grupos servidos
  # pelo painel.
  if [ "${TSA_SKIP_PREREQS:-0}" != 1 ]; then
    say "Preparando as ferramentas..."
    if "$CURL" -fsSL "$PREREQS_URL" -o "$TMP/prereqs.sh" 2>/dev/null; then
      TSA_ONLY_PREREQS=1 /bin/bash "$TMP/prereqs.sh" || true
    else
      printf 'Não consegui baixar o preparo das ferramentas. Rode depois:\n  curl -fsSL %s | TSA_ONLY_PREREQS=1 bash\n' "$PREREQS_URL"
    fi
  fi
  "$OPEN" "$APP" >/dev/null 2>&1 || true
}

ler_opcoes(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --perfil)
        [ $# -ge 2 ] && perfil_valido "$2" || die "--perfil aceita: $PERFIS"
        PERFIL="$2"; shift 2 ;;
      --sem-agendador) SEM_AGENDADOR_OPC=1; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}

main(){
  [ "$(uname -s)" = Darwin ] || die "Este instalador é para macOS."
  [ "$(uname -m)" = arm64 ] || die "O TSA roda só em Mac com chip Apple (M1 ou mais novo)."
  ler_opcoes "$@"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsa-instalar.XXXXXX")"
  chmod 700 "$TMP"
  preparar_js

  retomar_troca
  ID=""; API=""
  if cadastrada; then
    if [ -d "$APP" ]; then CASO=B1; else CASO=C; fi
  elif [ -e "$APP" ]; then CASO=B2
  else CASO=A; fi

  case "$CASO" in
    B1) caso_b1; return 0 ;;
    B2)
      printf 'Este Mac já tem o TSA. Abra o TSA: a partir da versão nova ele termina o cadastro e passa a se atualizar sozinho. Se o seu TSA ainda não tem essa versão, atualize pelo comando de instalação que você já usa e abra o TSA.\n'
      return 0 ;;
    A)
      abrir_tty
      pedir_convite
      perguntar_setor ;;
    C)
      say "TSA cadastrado e sem o app: reinstalando."
      if [ ! -f "$PERFIL_JSON" ] && [ -z "$PERFIL" ]; then abrir_tty; perguntar_setor; fi ;;
  esac

  pedir_manifesto "$TMP/resposta.json"
  extrair_manifesto "$TMP/resposta.json"
  conferir_manifesto
  baixar
  instalar
  gravar_perfil
  marca_agendador
  if [ "$CASO" = A ]; then entregar_convite; fi
  ferramentas_e_abrir
  if [ "$CASO" = A ]; then printf '\nO TSA vai abrir e terminar o cadastro sozinho.\n'
  else printf '\nO TSA foi reinstalado e vai abrir.\n'; fi
}

main "$@"
