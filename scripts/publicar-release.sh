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
ARCHS="arm64 x64"
# Recursos que todo TSA.app precisa ter em Contents/Resources/tsa. Edite so aqui.
RECURSOS_OBRIGATORIOS="simulador gsd dna-embedded-release.json"
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
for c in gh git node pnpm shasum openssl hdiutil codesign lipo unzip curl; do
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
else
  # O normalize do app escolhe o primeiro arquivo que casa; limpa as saidas antigas antes.
  rm -rf "$DIST"/mac "$DIST"/mac-arm64 "$DIST"/tsa-release
  rm -f "$DIST"/*.dmg "$DIST"/*.zip "$DIST"/*.blockmap "$DIST"/latest-mac.yml
  (
    cd "$APP"
    pnpm install --frozen-lockfile
    TSA_ADHOC_SIGN=1 pnpm run build:mac
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
    x64:dmg) echo "orca-macos-x64.dmg" ;;
    arm64:zip) yml_urls | grep -- '-arm64-mac\.zip$' || true ;;
    x64:zip) yml_urls | grep -- '-mac\.zip$' | grep -v -- '-arm64-mac\.zip$' || true ;;
  esac
}

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

confere_app(){ # caminho do .app, arch
  local app="$1" arch="$2" plist exe archs res r dna
  plist="$app/Contents/Info.plist"
  codesign --verify --deep --strict "$app" 2>&1 || die "codesign falhou em $app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = "$APP_ID" ] || die "bundle id errado em $app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$APP_VERSAO" ] ||
    die "o app do DMG $arch nao e da versao $APP_VERSAO"
  exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
  archs="$(lipo -archs "$app/Contents/MacOS/$exe")"
  case "$arch:$archs" in
    arm64:*arm64*|x64:*x86_64*) ;;
    *) die "o DMG $arch traz binario $archs" ;;
  esac
  res="$app/Contents/Resources/tsa"
  [ -d "$res" ] || die "falta Contents/Resources/tsa no DMG $arch"
  for r in $RECURSOS_OBRIGATORIOS; do
    [ -e "$res/$r" ] || die "falta Resources/tsa/$r no DMG $arch"
    [ ! -d "$res/$r" ] || [ -n "$(ls -A "$res/$r")" ] || die "Resources/tsa/$r esta vazio no DMG $arch"
  done
  for r in $RECURSOS_OPCIONAIS; do
    if [ -e "$res/$r" ]; then
      [ -d "$res/$r" ] && [ -n "$(ls -A "$res/$r")" ] || die "Resources/tsa/$r existe mas esta vazio no DMG $arch"
      ok "  opcional presente: $r"
    else
      note "  opcional ausente: $r"
    fi
  done
  dna="$(node -p "const m=require('$res/dna-embedded-release.json').manifest; m.version+' '+m.id")"
  [ "$dna" = "$POLICY_DNA_VERSAO dna-ace-tsa-$POLICY_DNA_COMMIT" ] ||
    die "DNA embutido ($dna) difere do config/release-policy.json ($POLICY_DNA_VERSAO $POLICY_DNA_COMMIT)"
  ok "TSA.app $arch: codesign ok, $APP_ID $APP_VERSAO, binario $archs, recursos ok, DNA $POLICY_DNA_VERSAO"
}

for arch in $ARCHS; do
  MOUNT="$OUT/mnt-$arch"
  mkdir -p "$MOUNT"
  hdiutil attach "$OUT/tsa-macos-$arch.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet </dev/null ||
    die "nao consegui montar tsa-macos-$arch.dmg"
  a="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$a" ] || die "nenhum .app no DMG $arch"
  confere_app "$a" "$arch"
  detach
  rmdir "$OUT/mnt-$arch"

  lista="$(unzip -l "$OUT/tsa-macos-$arch.zip")"
  for r in $RECURSOS_OBRIGATORIOS; do
    grep -q "Contents/Resources/tsa/$r" <<<"$lista" || die "falta Resources/tsa/$r no zip $arch"
  done
  ok "zip $arch: recursos obrigatorios presentes"
done

# ------------------------------------------------------------------ d. artefatos
say "d. Checksums e manifesto"
(cd "$OUT" && shasum -a 256 tsa-macos-arm64.dmg tsa-macos-x64.dmg tsa-macos-arm64.zip tsa-macos-x64.zip >checksums-sha256.txt)
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
[ "$N_ART" = 4 ] || die "o manifesto tem $N_ART artefatos; esperava 4"
ok "tsa-release.json com 4 artefatos"

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

NOTAS="Instalador TSA $VERSAO para macOS (Apple Silicon e Intel), assinatura ad-hoc.

App $APP_VERSAO, commit $APP_COMMIT da branch $APP_BRANCH.
DNA $POLICY_DNA_VERSAO embutido. Inclui o simulador ACE.

Instalar:
curl -fsSL $PAGES_URL | bash"
ASSETS="$OUT/tsa-macos-arm64.dmg $OUT/tsa-macos-x64.dmg $OUT/tsa-macos-arm64.zip $OUT/tsa-macos-x64.zip $OUT/checksums-sha256.txt $OUT/tsa-release.json"

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

printf '\nPublicado. Os colaboradores ja podem instalar com:\n  curl -fsSL %s | bash\n' "$PAGES_URL"
printf 'Depois que o time instalar, feche o repositorio:\n  gh repo edit %s --visibility private --accept-visibility-change-consequences\n' "$REPO"
