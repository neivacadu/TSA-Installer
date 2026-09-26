#!/usr/bin/env bash
# Publica uma versao do instalador TSA para macOS.
#
#   scripts/publicar-release.sh <versao> --app <clone do AceOrca> [--sem-build] [--publicar]
#
# Sem --publicar, roda em ENSAIO: faz build e conferencias, gera os artefatos numa pasta
# temporaria e mostra o que faria. Nao cria tag, release, commit nem push.
# Com --publicar: commit da troca de tag no docs/install.sh, gh release create
# (pre-release), push da main e verificacao do Pages e dos checksums publicados.
# O script nunca muda a visibilidade do repositorio nem liga o Pages sozinho.
set -euo pipefail

REPO="neivacadu/TSA-Installer"
APP_BRANCH="tsa/integracao"
APP_ID="com.trafegosa.orca-tsa"
PAGES_URL="https://neivacadu.github.io/TSA-Installer/install.sh"
PAGES_TIMEOUT="${TSA_PAGES_TIMEOUT:-900}"
# Decisao do Cadu (25/09/2026): o TSA para Mac e so chip Apple. Mac Intel (x64) saiu de tudo.
ARCHS="arm64"
# Recursos que todo TSA.app precisa ter em Contents/Resources/tsa. Edite so aqui.
# tsa-version.json, app-trusted-keys.json e atualizador (leitor estrito do app): WO-10.
RECURSOS_OBRIGATORIOS="simulador gsd dna-embedded-release.json tsa-version.json app-trusted-keys.json atualizador"
# Conferidos so quando existem: outras frentes ainda estao acrescentando.
RECURSOS_OPCIONAIS="ace-skills ace-knowledge"

VERSAO=""
APP=""
SEM_BUILD=0
PUBLICAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --sem-build) SEM_BUILD=1; shift ;;
    --publicar) PUBLICAR=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "opcao desconhecida: $1" >&2; exit 2 ;;
    *) VERSAO="$1"; shift ;;
  esac
done

# O remoto do instalador nem sempre se chama "origin": no worktree do Master cada
# repositorio entra como um remoto proprio. Descobrimos pelo endereco, nao pelo nome.
remoto_do_repo(){
  git -C "$1" remote -v 2>/dev/null | awk -v r="$2" '$3=="(fetch)" && index($2, r){print $1; exit}'
}

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
note(){ printf '  \033[0;33m!\033[0m %s\n' "$1"; }
faria(){ printf '  [ensaio] faria: %s\n' "$1"; }
die(){ printf '\n\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# Versao TSA dentro do app (WO-10; APP-RELEASE-CONTRATO v1.2, secoes 3 e 10). Vale ate a F5,
# enquanto a release sai pelo GitHub. O build:mac recebe TSA_RELEASE_VERSION e grava
# Contents/Resources/tsa/tsa-version.json com canal "aprovada". Sem isso, a regra de troca
# (secao 10) leria a release como 0.0.0 ou como a build local de quem gerou o DMG.
# Falha fechada: arquivo ausente, JSON invalido ou qualquer campo fora recusa a release.
# Os dois arquivos sao lidos com o leitor JSON estrito do proprio app (atualizador/manifesto.mjs
# de dentro do DMG): o que o app instalado recusaria, a publicacao recusa antes (WO10-CX-03).
confere_versao_tsa(){ # pasta Resources/tsa, versao da release, commit completo do app, rotulo
  local saida
  saida="$(node --input-type=module -e '
    import fs from "node:fs"
    import { pathToFileURL } from "node:url"
    const [res, versao, commit] = process.argv.slice(1)
    const arq = res + "/tsa-version.json"
    const falha = (m) => { console.log(m); process.exit(1) }
    let app
    try { app = await import(pathToFileURL(res + "/atualizador/manifesto.mjs").href) } catch { falha("nao consegui carregar atualizador/manifesto.mjs do app") }
    if (typeof app.lerJsonEstrito !== "function" || typeof app.lerInstalado !== "function") falha("atualizador/manifesto.mjs sem lerJsonEstrito/lerInstalado")
    let st
    try { st = fs.lstatSync(arq) } catch { falha("falta tsa-version.json (o build:mac rodou sem TSA_RELEASE_VERSION?)") }
    if (!st.isFile()) falha("tsa-version.json nao e um arquivo comum")
    let v
    try { v = app.lerJsonEstrito(fs.readFileSync(arq)) } catch { falha("tsa-version.json nao e JSON estrito valido (o app nao leria)") }
    if (!v || typeof v !== "object" || Array.isArray(v)) falha("tsa-version.json nao e um objeto")
    if (v.tsa !== versao) falha("tsa-version.json diz tsa " + JSON.stringify(v.tsa) + "; a release e " + versao)
    if (v.canal !== "aprovada") falha("tsa-version.json tem canal " + JSON.stringify(v.canal) + "; a release exige \"aprovada\"")
    const id = v.build_id
    if (typeof id !== "string" || !/^[0-9a-f]{7,12}\.[0-9]{8}T[0-9]{6}Z$/.test(id)) falha("build_id ausente ou fora do formato: " + JSON.stringify(id))
    if (typeof v.commit !== "string" || !/^[0-9a-f]{7,12}$/.test(v.commit)) falha("commit invalido no tsa-version.json: " + JSON.stringify(v.commit))
    if (!commit.startsWith(v.commit)) falha("o app do DMG e do commit " + v.commit + ", nao de " + commit.slice(0, 9) + " (dist/ antigo?)")
    // gerado_em sai de toISOString() no gerador. Exigir a mesma forma exata barra data que o
    // Date normalizaria (2026-02-30 virando 03-02) e fecha a checagem de calendario da secao 3.
    const g = v.gerado_em
    const d = new Date(typeof g === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$/.test(g) ? g : NaN)
    if (Number.isNaN(d.getTime()) || d.toISOString() !== g) falha("gerado_em invalido: " + JSON.stringify(g))
    const carimbo = d.toISOString().slice(0, 19).replace(/[-:]/g, "") + "Z"
    if (id !== v.commit + "." + carimbo) falha("build_id " + id + " nao bate com commit + gerado_em (" + v.commit + "." + carimbo + ")")
    // A regra de troca (secao 10) le o arquivo pelo lerInstalado: ele tem de ver o mesmo.
    const inst = app.lerInstalado(arq)
    if (inst.build_id !== id || inst.versao_rotulo !== versao) falha("o lerInstalado do app nao le a versao e o build_id deste arquivo")
    console.log(v.tsa + " (" + v.canal + ") " + id)
  ' -- "$1" "$2" "$3")" || die "${4:-app}: ${saida:-falha ao ler tsa-version.json}"
  ok "  versao TSA: $saida"
}

# Chaves que o app confia para aceitar uma atualizacao (contrato, secao 2.2, item 6):
# objeto { key_id: PEM SPKI Ed25519 }, com a chave real da F1. As regras sao as mesmas do
# verificador do app (tsa-app resources/tsa/atualizador/manifesto.mjs, chaveConfiavel): uma
# entrada irregular faz o app reprovar o arquivo inteiro, entao aqui ela recusa a release.
# atalho: regras copiadas, nao importadas, porque o chaveConfiavel nao e exportado. Teto: se o
# app mudar RE_KEY_ID ou o PEM aceito, mudar aqui junto. Saida: o app exportar a validacao.
APP_KEY_ID="tsa-cadu-app-release-v1"
confere_chaves_app(){ # pasta Resources/tsa, rotulo
  local saida
  saida="$(node --input-type=module -e '
    import fs from "node:fs"
    import crypto from "node:crypto"
    import { pathToFileURL } from "node:url"
    const [res, exigida] = process.argv.slice(1)
    const arq = res + "/app-trusted-keys.json"
    const falha = (m) => { console.log(m); process.exit(1) }
    let app
    try { app = await import(pathToFileURL(res + "/atualizador/manifesto.mjs").href) } catch { falha("nao consegui carregar atualizador/manifesto.mjs do app") }
    if (typeof app.lerJsonEstrito !== "function") falha("atualizador/manifesto.mjs sem lerJsonEstrito")
    let st
    try { st = fs.lstatSync(arq) } catch { falha("falta app-trusted-keys.json") }
    if (!st.isFile()) falha("app-trusted-keys.json nao e um arquivo comum")
    let k
    try { k = app.lerJsonEstrito(fs.readFileSync(arq)) } catch { falha("app-trusted-keys.json nao e JSON estrito valido (o app nao leria)") }
    if (!k || typeof k !== "object" || Array.isArray(k) || Object.getPrototypeOf(k) !== Object.prototype) falha("app-trusted-keys.json nao e um objeto { key_id: PEM }")
    const ids = Object.keys(k)
    if (!ids.includes(exigida)) falha("app-trusted-keys.json sem a chave " + exigida)
    const prefixo = Buffer.from("302a300506032b6570032100", "hex")
    for (const id of ids) {
      if (!/^[a-z0-9][a-z0-9-]{2,62}$/.test(id)) falha("key_id fora do formato: " + JSON.stringify(id))
      const pem = k[id]
      const r = typeof pem === "string" && /^-----BEGIN PUBLIC KEY-----\n([A-Za-z0-9+/]{59}=)\n-----END PUBLIC KEY-----\n$/.exec(pem)
      if (!r) falha("chave " + JSON.stringify(id) + " nao e um PEM Ed25519 exato (uma chave, com quebra de linha no fim)")
      const der = Buffer.from(r[1], "base64")
      if (der.length !== 44 || der.toString("base64") !== r[1] || !der.subarray(0, 12).equals(prefixo)) falha("chave " + JSON.stringify(id) + " nao e SPKI Ed25519")
      let tipo
      try { tipo = crypto.createPublicKey({ key: der, format: "der", type: "spki" }).asymmetricKeyType } catch { falha("chave " + JSON.stringify(id) + " nao abre como chave publica") }
      if (tipo !== "ed25519") falha("chave " + JSON.stringify(id) + " nao e ed25519")
    }
    console.log(ids.join(", "))
  ' -- "$1" "$APP_KEY_ID")" || die "${2:-app}: ${saida:-falha ao ler app-trusted-keys.json}"
  ok "  chaves de atualizacao: $saida"
}

confere_app(){ # caminho do .app, arch, rotulo (padrao "DMG <arch>")
  local app="$1" arch="$2" rot="${3:-DMG $2}" plist exe archs res r dna
  plist="$app/Contents/Info.plist"
  codesign --verify --deep --strict "$app" 2>&1 || die "codesign falhou em $app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = "$APP_ID" ] || die "bundle id errado em $app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$APP_VERSAO" ] ||
    die "o app do $rot nao e da versao $APP_VERSAO"
  exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
  archs="$(lipo -archs "$app/Contents/MacOS/$exe")"
  case "$arch:$archs" in
    arm64:arm64) ;;
    *) die "o $rot traz binario $archs" ;;
  esac
  res="$app/Contents/Resources/tsa"
  [ -d "$res" ] || die "falta Contents/Resources/tsa no $rot"
  for r in $RECURSOS_OBRIGATORIOS; do
    [ -e "$res/$r" ] || die "falta Resources/tsa/$r no $rot"
    [ ! -d "$res/$r" ] || [ -n "$(ls -A "$res/$r")" ] || die "Resources/tsa/$r esta vazio no $rot"
  done
  for r in $RECURSOS_OPCIONAIS; do
    if [ -e "$res/$r" ]; then
      [ -d "$res/$r" ] && [ -n "$(ls -A "$res/$r")" ] || die "Resources/tsa/$r existe mas esta vazio no $rot"
      ok "  opcional presente: $r"
    else
      note "  opcional ausente: $r"
    fi
  done
  confere_versao_tsa "$res" "$VERSAO" "$APP_COMMIT" "$rot"
  confere_chaves_app "$res" "$rot"
  # o caminho vai por argumento, nunca dentro do codigo JS: aspas no caminho nao quebram nada
  dna="$(node -e 'const m=require(process.argv[1]).manifest; console.log(m.version+" "+m.id)' -- "$res/dna-embedded-release.json")" ||
    die "nao consegui ler o dna-embedded-release.json do $rot"
  [ "$dna" = "$POLICY_DNA_VERSAO dna-ace-tsa-$POLICY_DNA_COMMIT" ] ||
    die "DNA embutido ($dna) difere do config/release-policy.json ($POLICY_DNA_VERSAO $POLICY_DNA_COMMIT)"
  ok "TSA.app $arch: codesign ok, $APP_ID $APP_VERSAO, binario $archs, recursos ok, versao TSA $VERSAO aprovada, DNA $POLICY_DNA_VERSAO"
}

# O zip leva o mesmo app que o DMG (WO10-CX-04 a 08). A listagem so serve para recusar o que o
# extrator resolveria de forma ambigua: nome repetido (tambem so por caixa), caminho nao
# canonico (//, ./, ../, barra no inicio, barra invertida) e mais de uma raiz. Depois o zip e
# extraido com ditto e o app extraido passa pelo mesmo confere_app do DMG, com os arquivos
# conferidos iguais byte a byte aos do DMG. Assim vale o que de fato sai do zip no disco.
ZIP_IGUAL_AO_DMG="tsa-version.json app-trusted-keys.json atualizador/manifesto.mjs dna-embedded-release.json"
confere_zip(){ # caminho do zip, pasta Resources/tsa do DMG ja conferido (montado), arch, pasta de trabalho
  local zip="$1" ref="$2" arch="$3" dir="$4" nomes raiz f
  nomes="$(unzip -Z1 "$zip")" || die "nao consegui listar o zip $arch"
  [ -n "$nomes" ] || die "o zip $arch esta vazio"
  # here-string, sem pipe no primeiro comando: grep -q ou awk saindo cedo nao gera SIGPIPE
  [ -z "$(tr '[:upper:]' '[:lower:]' <<<"$nomes" | sort | uniq -d)" ] ||
    die "o zip $arch tem entradas com nome repetido (sem contar maiusculas)"
  awk '{ n = split($0, c, "/")
         for (i = 1; i <= n; i++) if ((c[i] == "" && i != n) || c[i] == "." || c[i] == "..") ruim = 1
         if (index($0, "\\")) ruim = 1 }
       END { exit ruim }' <<<"$nomes" || die "o zip $arch tem caminho nao canonico"
  raiz="$(cut -d/ -f1 <<<"$nomes" | sort -u)"
  [ "$(grep -c . <<<"$raiz")" = 1 ] && [ "${raiz%.app}" != "$raiz" ] ||
    die "o zip $arch nao tem exatamente um .app na raiz, e nada fora dele"
  rm -rf "$dir"
  mkdir -p "$dir"
  ditto -x -k "$zip" "$dir" || die "nao consegui extrair o zip $arch"
  [ "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] && [ -d "$dir/$raiz" ] ||
    die "o zip $arch extraido nao deu um unico $raiz"
  confere_app "$dir/$raiz" "$arch" "zip $arch"
  for f in $ZIP_IGUAL_AO_DMG; do
    cmp -s "$dir/$raiz/Contents/Resources/tsa/$f" "$ref/$f" ||
      die "Resources/tsa/$f do zip $arch difere do DMG conferido"
  done
  rm -rf "$dir"
  ok "zip $arch: app extraido conferido; versao, chaves, leitor e DNA iguais ao DMG"
}

# O teste (scripts/test-publicar-release.sh) carrega so as funcoes acima, sem gh, build nem rede.
if [ "${TSA_PUBLICAR_SO_FUNCOES:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

echo "$VERSAO" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$' ||
  die "uso: scripts/publicar-release.sh <versao, ex.: 0.3.0> --app <clone do AceOrca> [--sem-build] [--publicar]"
[ -n "$APP" ] || die "informe o clone do app com --app <caminho>"
APP="$(cd "$APP" && pwd)" || die "diretorio do app nao existe: $APP"
DIST="$APP/dist"
TAG="tsa-installer-v${VERSAO}-adhoc"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/tsa-release-${VERSAO}.XXXXXX")"
MOUNT=""
detach(){ if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; MOUNT=""; fi; }
trap detach EXIT

if [ "$PUBLICAR" = 1 ]; then MODO="PUBLICACAO"; else MODO="ENSAIO (nada sera publicado)"; fi
printf 'Versao %s, tag %s\nModo: %s\nApp: %s\nArtefatos: %s\n' "$VERSAO" "$TAG" "$MODO" "$APP" "$OUT"

# ------------------------------------------------------------------ a. pre-checagem
say "a. Pre-checagem"
for c in gh git node pnpm shasum openssl hdiutil codesign lipo unzip ditto curl; do
  command -v "$c" >/dev/null || die "comando ausente: $c"
done
gh auth status >/dev/null 2>&1 || die "gh nao esta logado. Rode: gh auth login"
REPO_INFO="$(gh api "repos/$REPO" --jq '[.permissions.push, .private] | @tsv')" ||
  die "gh nao consegue ler $REPO"
PODE_ESCREVER="$(printf '%s' "$REPO_INFO" | cut -f1)"
PRIVADO="$(printf '%s' "$REPO_INFO" | cut -f2)"
[ "$PODE_ESCREVER" = true ] || die "a conta do gh nao tem permissao de escrita em $REPO"
ok "gh logado com escrita em $REPO"

git -C "$APP" rev-parse --git-dir >/dev/null 2>&1 || die "$APP nao e um repositorio git"
APP_BRANCH_ATUAL="$(git -C "$APP" branch --show-current)"
# O worktree do Master usa nome proprio e acompanha a branch certa no remoto.
# Vale a branch de destino, nao o nome local.
APP_UPSTREAM="$(git -C "$APP" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo '')"
if [ "$APP_BRANCH_ATUAL" != "$APP_BRANCH" ] && [ "${APP_UPSTREAM#*/}" != "$APP_BRANCH" ]; then
  die "o app esta na branch '$APP_BRANCH_ATUAL' (acompanha '${APP_UPSTREAM:-nenhuma}'); precisa ser $APP_BRANCH"
fi
[ -z "$(git -C "$APP" status --porcelain)" ] || die "a arvore do app tem mudancas. Rode: git -C $APP status"
APP_COMMIT="$(git -C "$APP" rev-parse HEAD)"
ok "app em $APP_BRANCH, arvore limpa, commit $APP_COMMIT"

# TSA novo nasce com o DNA mais novo, sem depender da Central: a build so sai se o DNA
# embutido for o ultimo commit do main do DNA e bater com o config/release-policy.json.
POLICY="$ROOT/config/release-policy.json"
DNA_GH="$(node -p "require('$POLICY').dnaRepository")"
DNA_MAIN="$(gh api "repos/$DNA_GH/commits/main" --jq .sha)" || die "nao consegui ler o main de $DNA_GH"
read -r EMB_VERSAO EMB_COMMIT < <(node -e '
  const m = require(process.argv[1]).manifest
  console.log(m.version, m.id.replace(/^dna-ace-tsa-/, ""))' "$APP/resources/tsa/dna-embedded-release.json")
[ "$EMB_COMMIT" = "$DNA_MAIN" ] || die "o DNA embutido ($EMB_VERSAO, commit ${EMB_COMMIT:0:9}) nao e o ultimo aprovado: o main de $DNA_GH esta em ${DNA_MAIN:0:9}.
  Gere, assine e publique o DNA novo na Central e copie o mesmo envelope para
  resources/tsa/dna-embedded-release.json (memoria dna-release-central)."
POLICY_DNA_VERSAO="$(node -p "require('$POLICY').dnaReleaseVersion")"
POLICY_DNA_COMMIT="$(node -p "require('$POLICY').dnaApprovedCommit")"
[ "$POLICY_DNA_VERSAO $POLICY_DNA_COMMIT" = "$EMB_VERSAO $EMB_COMMIT" ] ||
  die "config/release-policy.json ($POLICY_DNA_VERSAO ${POLICY_DNA_COMMIT:0:9}) difere do DNA embutido ($EMB_VERSAO ${EMB_COMMIT:0:9}). Atualize dnaReleaseVersion e dnaApprovedCommit."
ok "DNA embutido $EMB_VERSAO e o ultimo do main de $DNA_GH"

REMOTO="$(remoto_do_repo "$ROOT" "$REPO")"
[ -n "$REMOTO" ] || die "nenhum remoto do instalador aponta para $REPO"
[ -z "$(git -C "$ROOT" ls-remote --tags "$REMOTO" "refs/tags/$TAG")" ] || die "a tag $TAG ja existe no remoto"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then die "a release $TAG ja existe"; fi
ok "a tag $TAG ainda nao existe"

# Gates que so bloqueiam a publicacao. No ensaio, so avisam.
BLOQUEIOS=""
bloqueio(){ BLOQUEIOS="${BLOQUEIOS}  - $1"$'\n'; }
ROOT_BRANCH="$(git -C "$ROOT" branch --show-current)"
# O worktree do Master usa nome proprio e acompanha main no remoto; vale o destino.
ROOT_UPSTREAM="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo '')"
[ "$ROOT_BRANCH" = main ] || [ "${ROOT_UPSTREAM#*/}" = main ] || bloqueio "o instalador precisa ir para main (esta em '$ROOT_BRANCH', acompanha '${ROOT_UPSTREAM:-nenhuma}')"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || bloqueio "a arvore do instalador tem mudancas (git -C $ROOT status)"
git -C "$ROOT" fetch -q "$REMOTO" main 2>/dev/null || bloqueio "nao consegui buscar $REMOTO/main"
git -C "$ROOT" merge-base --is-ancestor "$REMOTO/main" HEAD 2>/dev/null || bloqueio "o HEAD do instalador nao contem $REMOTO/main; atualize antes (git pull)"
if [ "$PRIVADO" = true ]; then
  bloqueio "o repositorio $REPO esta PRIVADO. Para abrir: gh repo edit $REPO --visibility public --accept-visibility-change-consequences"
elif ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  bloqueio "o GitHub Pages esta desligado. Para ligar: gh api -X POST repos/$REPO/pages -f 'source[branch]=main' -f 'source[path]=/docs'"
fi
if [ -n "$BLOQUEIOS" ]; then
  [ "$PUBLICAR" = 1 ] && die "a publicacao esta bloqueada:"$'\n'"$BLOQUEIOS"
  note "para publicar, falta resolver:"
  printf '%s' "$BLOQUEIOS"
else
  ok "instalador na main, limpo, repositorio publico e Pages ligado"
fi

# ------------------------------------------------------------------ b. build
say "b. Build do app"
(cd "$APP" && pnpm run -s verify:tsa-macos-release)
if [ "$SEM_BUILD" = 1 ]; then
  # atalho: reaproveita o dist/ sem rebuild. O prepare do app nao roda aqui porque o
  # normalize dele pega o primeiro zip em ordem alfabetica, e um dist/ com builds
  # antigos faria ele copiar o zip errado. A escolha abaixo usa o latest-mac.yml.
  note "--sem-build: reaproveitando $DIST sem build e sem prepare:tsa-macos-release"
  note "o dist/ precisa ter saido de: TSA_RELEASE_VERSION=$VERSAO pnpm run build:mac (senao a conferencia recusa)"
else
  # O normalize do app escolhe o primeiro arquivo que casa; limpa as saidas antigas antes.
  rm -rf "$DIST"/mac "$DIST"/mac-arm64 "$DIST"/tsa-release
  rm -f "$DIST"/*.dmg "$DIST"/*.zip "$DIST"/*.blockmap "$DIST"/latest-mac.yml
  (
    cd "$APP"
    # O build:mac empacota so arm64 (dmg e zip): o alvo mac do electron-builder do app nao tem
    # mais x64. O build:mobile-web (dentro do build:desktop) precisa das dependencias do mobile/.
    pnpm run install:release
    (cd mobile && pnpm install --frozen-lockfile)
    # TSA_RELEASE_VERSION faz o build:mac gravar tsa-version.json com canal "aprovada" (WO-10).
    TSA_ADHOC_SIGN=1 TSA_RELEASE_VERSION="$VERSAO" pnpm run build:mac
    TSA_RELEASE_VERSION="$VERSAO" TSA_SOURCE_COMMIT="$APP_COMMIT" pnpm run prepare:tsa-macos-release
  )
  ok "build e prepare concluidos"
fi

# ------------------------------------------------------------------ c. conferencias
say "c. Conferencias"
YML="$DIST/latest-mac.yml"
[ -f "$YML" ] || die "nao achei $YML; o build nao terminou"
APP_VERSAO="$(sed -n 's/^version: //p' "$YML")"
[ -n "$APP_VERSAO" ] || die "latest-mac.yml sem versao"
# nome e sha512 (base64) de cada arquivo listado pelo build
yml_sha(){ awk -v n="$1" '$1=="-" && $2=="url:" {u=$3} $1=="sha512:" && u==n {print $2; exit}' "$YML"; }
yml_urls(){ sed -n 's/^  - url: //p' "$YML"; }
ok "build do app: versao $APP_VERSAO"

origem_de(){ # arch tipo
  case "$1:$2" in
    arm64:dmg) echo "orca-macos-arm64.dmg" ;;
    arm64:zip) yml_urls | grep -- '-arm64-mac\.zip$' || true ;;
  esac
}

# Um build com x64 veio de uma config antiga do app: recusa antes de copiar qualquer coisa.
if yml_urls | grep -v -- '-arm64' | grep -q .; then
  die "latest-mac.yml traz artefato que nao e arm64 (Mac Intel saiu da release):
$(yml_urls | grep -v -- '-arm64' | sed 's/^/    /')"
fi

for arch in $ARCHS; do
  for tipo in dmg zip; do
    src="$(origem_de "$arch" "$tipo")"
    [ "$(printf '%s\n' "$src" | grep -c .)" = 1 ] || die "latest-mac.yml nao aponta um unico $tipo $arch (achei: ${src:-nada})"
    yml_urls | grep -qxF "$src" || die "$src nao e deste build (fora do latest-mac.yml)"
    [ -s "$DIST/$src" ] || die "arquivo ausente ou vazio: $DIST/$src"
    esperado="$(yml_sha "$src")"
    atual="$(openssl dgst -sha512 -binary "$DIST/$src" | openssl base64 -A)"
    [ "$esperado" = "$atual" ] || die "$src nao bate com o sha512 do latest-mac.yml"
    destino="tsa-macos-$arch.$tipo"
    cp -c "$DIST/$src" "$OUT/$destino" 2>/dev/null || cp "$DIST/$src" "$OUT/$destino"
    ok "$destino <- $src (sha512 confere com o build)"
  done
done

for arch in $ARCHS; do
  MOUNT="$OUT/mnt-$arch"
  mkdir -p "$MOUNT"
  hdiutil attach "$OUT/tsa-macos-$arch.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet </dev/null ||
    die "nao consegui montar tsa-macos-$arch.dmg"
  a="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$a" ] || die "nenhum .app no DMG $arch"
  confere_app "$a" "$arch"
  # com o DMG ainda montado: o zip e comparado com os arquivos que acabaram de ser conferidos
  confere_zip "$OUT/tsa-macos-$arch.zip" "$a/Contents/Resources/tsa" "$arch" "$OUT/zip-$arch"
  detach
  rmdir "$OUT/mnt-$arch"
done

# ------------------------------------------------------------------ d. artefatos
say "d. Checksums e manifesto"
(cd "$OUT" && shasum -a 256 tsa-macos-arm64.dmg tsa-macos-arm64.zip >checksums-sha256.txt)
# mesmo awk do docs/install.sh: coluna 2 e o nome sem caminho
for arch in $ARCHS; do
  n="tsa-macos-$arch.dmg"
  h="$(awk -v n="$n" '$2==n{print $1}' "$OUT/checksums-sha256.txt")"
  [ "$h" = "$(shasum -a 256 "$OUT/$n" | awk '{print $1}')" ] || die "checksums-sha256.txt nao funciona com o awk do install.sh para $n"
done
ok "checksums-sha256.txt no formato do install.sh"
sed 's/^/    /' "$OUT/checksums-sha256.txt"

(
  cd "$ROOT"
  TSA_DIST_DIR="$OUT" GITHUB_REF_NAME="$TAG" TSA_RELEASE_VERSION="$VERSAO" TSA_APP_COMMIT="$APP_COMMIT" \
    TSA_RELEASE_CHANNEL=adhoc TSA_RELEASE_STATE=PUBLISHED node scripts/generate-release-manifest.mjs
  node scripts/verify-manifest.mjs manifests/tsa-release.json
)
cp "$ROOT/manifests/tsa-release.json" "$OUT/tsa-release.json"
# Why: node -p colors numbers when the build env sets FORCE_COLOR, so print plain text.
N_ART="$(node -e "process.stdout.write(String(require('$OUT/tsa-release.json').artifacts.length))")"
[ "$N_ART" = 2 ] || die "o manifesto tem $N_ART artefatos; esperava 2 (dmg e zip arm64)"
ok "tsa-release.json com 2 artefatos"

# ------------------------------------------------------------------ e. tag do instalador
say "e. Tag no docs/install.sh"
sed -E "s|^RELEASE_TAG=\"\\\$\\{TSA_RELEASE_TAG:-[^}]*\\}\"|RELEASE_TAG=\"\${TSA_RELEASE_TAG:-$TAG}\"|" \
  "$ROOT/docs/install.sh" >"$OUT/install.sh"
grep -qF "RELEASE_TAG=\"\${TSA_RELEASE_TAG:-$TAG}\"" "$OUT/install.sh" || die "nao consegui trocar a RELEASE_TAG"
bash -n "$OUT/install.sh" || die "install.sh com a tag nova tem erro de sintaxe"
if cmp -s "$ROOT/docs/install.sh" "$OUT/install.sh"; then
  note "a tag ja era $TAG"
else
  { diff -u "$ROOT/docs/install.sh" "$OUT/install.sh" || true; } | sed -n '3,$p' | grep '^[-+]' | sed 's/^/    /'
fi

NOTAS="Instalador TSA $VERSAO para macOS com chip Apple (M1 ou mais novo), assinatura ad-hoc.
Mac Intel nao e suportado.

App $APP_VERSAO, commit $APP_COMMIT da branch $APP_BRANCH.
DNA $POLICY_DNA_VERSAO embutido. Inclui o simulador ACE.

Instalar:
curl -fsSL $PAGES_URL | bash"
ASSETS="$OUT/tsa-macos-arm64.dmg $OUT/tsa-macos-arm64.zip $OUT/checksums-sha256.txt $OUT/tsa-release.json"

# ------------------------------------------------------------------ f. publicacao
say "f. Publicacao"
if [ "$PUBLICAR" != 1 ]; then
  faria "copiar $OUT/install.sh para docs/install.sh e commitar: release: aponta o instalador pra $TAG"
  faria "gh release create $TAG -R $REPO --prerelease --target <sha da origin/main> --title \"TSA macOS $VERSAO\" com:"
  for f in $ASSETS; do printf '           %s (%s bytes)\n' "$(basename "$f")" "$(stat -f %z "$f")"; done
  faria "git push $REMOTO HEAD:main"
  faria "esperar $PAGES_URL mostrar $TAG (ate ${PAGES_TIMEOUT} s) e conferir os checksums publicados"
  printf '\nNotas da release:\n%s\n' "$NOTAS" | sed 's/^/    /'
  printf '\nEnsaio concluido. Nada foi publicado. Artefatos em:\n  %s\n' "$OUT"
  exit 0
fi

cp "$OUT/install.sh" "$ROOT/docs/install.sh"
git -C "$ROOT" add docs/install.sh
git -C "$ROOT" commit -q -m "release: aponta o instalador pra $TAG"
ok "commit $(git -C "$ROOT" rev-parse --short HEAD)"

# A release sai antes do push: o install.sh publicado nunca aponta para tag inexistente.
REMOTE_MAIN="$(git -C "$ROOT" ls-remote "$REMOTO" refs/heads/main | cut -f1)"
# shellcheck disable=SC2086
gh release create "$TAG" -R "$REPO" --prerelease --target "$REMOTE_MAIN" \
  --title "TSA macOS $VERSAO" --notes "$NOTAS" $ASSETS
ok "release $TAG criada"
git -C "$ROOT" push "$REMOTO" HEAD:main
ok "main enviada"

# ------------------------------------------------------------------ g. verificacao
say "g. Verificacao do que foi publicado"
fim=$(( $(date +%s) + PAGES_TIMEOUT ))
publicado=""
while :; do
  publicado="$(curl -fsSL --max-time 20 "$PAGES_URL?v=$(date +%s)" 2>/dev/null || true)"
  grep -qF "RELEASE_TAG=\"\${TSA_RELEASE_TAG:-$TAG}\"" <<<"$publicado" && break
  [ "$(date +%s)" -lt "$fim" ] || die "o Pages nao mostrou $TAG em ${PAGES_TIMEOUT} s. Confira: curl -fsSL $PAGES_URL | grep RELEASE_TAG"
  sleep 15
done
ok "Pages responde 200 e o install.sh publicado aponta para $TAG"

remoto="$(curl -fsSL --max-time 60 "https://github.com/$REPO/releases/download/$TAG/checksums-sha256.txt")" ||
  die "nao consegui baixar o checksums-sha256.txt da release"
for arch in $ARCHS; do
  n="tsa-macos-$arch.dmg"
  [ "$(printf '%s\n' "$remoto" | awk -v n="$n" '$2==n{print $1}')" = "$(shasum -a 256 "$OUT/$n" | awk '{print $1}')" ] ||
    die "o checksum publicado de $n nao bate com o arquivo local"
  curl -fsIL --max-time 60 "https://github.com/$REPO/releases/download/$TAG/$n" >/dev/null ||
    die "o download de $n nao responde"
done
ok "checksums publicados batem com os DMGs e os downloads respondem"

# ------------------------------------------------------------------ h. copia local
# Decisão do Cadu (19/09/2026): na máquina ficam só a versão atual e a anterior, para poder voltar.
say "h. Copia local em ~/Downloads"
LOCAL_DIR="$HOME/Downloads/TSA-$VERSAO"
mkdir -p "$LOCAL_DIR"
for arch in $ARCHS; do cp -f "$OUT/tsa-macos-$arch.dmg" "$LOCAL_DIR/"; done
ok "instaladores em $LOCAL_DIR"
ls -d "$HOME/Downloads"/TSA-[0-9]*.[0-9]*.[0-9]* 2>/dev/null | sed 's#.*/TSA-##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
  sort -t. -k1,1n -k2,2n -k3,3n | sed '$d' | sed '$d' | while read -r antiga; do
    rm -rf "$HOME/Downloads/TSA-$antiga" && ok "apagada a copia local antiga TSA-$antiga"
  done

printf '\nPublicado. Os colaboradores ja podem instalar com:\n  curl -fsSL %s | bash\n' "$PAGES_URL"
printf 'Depois que o time instalar, feche o repositorio:\n  gh repo edit %s --visibility private --accept-visibility-change-consequences\n' "$REPO"
