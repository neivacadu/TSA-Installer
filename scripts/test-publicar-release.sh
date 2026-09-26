#!/bin/bash
# Testa a conferencia do TSA.app no publicar-release.sh (WO-10): tsa-version.json e
# app-trusted-keys.json dentro de Contents/Resources/tsa. Sem gh, build, rede nem DMG real:
# carrega so as funcoes do script (TSA_PUBLICAR_SO_FUNCOES=1) e roda confere_app num
# TSA.app falso, numa pasta com espaco e aspas no caminho. codesign e lipo sao falsos;
# PlistBuddy e node sao os reais. O leitor estrito (atualizador/manifesto.mjs) vem do app:
# TSA_APP aponta o clone do AceOrca (padrao: o worktree tsa-app ao lado do instalador).
#   bash scripts/test-publicar-release.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/publicar-release.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/tsa-publicar-test.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
WORK="$BASE/pasta com espaço e 'aspas'"
mkdir -p "$WORK/bin"
MANIFESTO="${TSA_APP:-$ROOT/../tsa-app}/resources/tsa/atualizador/manifesto.mjs"
[ -f "$MANIFESTO" ] || { echo "nao achei $MANIFESTO; aponte TSA_APP para o clone do app" >&2; exit 1; }

printf '#!/bin/bash\nexit 0\n' >"$WORK/bin/codesign"
printf '#!/bin/bash\necho arm64\n' >"$WORK/bin/lipo"
chmod +x "$WORK/bin/codesign" "$WORK/bin/lipo"

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf '  FALHA %s\n' "$1"; }

VERSAO_REL="0.9.1"
COMMIT_FULL="abc123def4567890abc123def4567890abc123de"
COMMIT="abc123def"
GERADO="2026-09-26T01:02:03.456Z"
BUILD_ID="$COMMIT.20260926T010203Z"
DNA_V="1.0.20"; DNA_C="0123456789abcdef0123456789abcdef01234567"

# $(...) come a quebra de linha final do PEM; o "x" no fim preserva o PEM exato.
pem(){ node -e 'const {generateKeyPairSync}=require("crypto");const o=process.argv[1]==="rsa"?{modulusLength:2048}:{};process.stdout.write(generateKeyPairSync(process.argv[1],o).publicKey.export({type:"spki",format:"pem"})+"x")' "$1"; }
PEM_ED="$(pem ed25519)"; PEM_ED="${PEM_ED%x}"
PEM_ED2="$(pem ed25519)"; PEM_ED2="${PEM_ED2%x}"
PEM_RSA="$(pem rsa)"; PEM_RSA="${PEM_RSA%x}"
chaves_json(){ node -e 'const o={};for(let i=1;i<process.argv.length;i+=2)o[process.argv[i]]=process.argv[i+1];console.log(JSON.stringify(o,null,2))' -- "$@"; }

# monta um TSA.app correto; cada cenario estraga uma coisa depois
monta(){
  APPDIR="$WORK/caso $1/TSA.app"
  rm -rf "$WORK/caso $1"
  local c="$APPDIR/Contents" res="$APPDIR/Contents/Resources/tsa"
  mkdir -p "$c/MacOS" "$res/simulador" "$res/gsd" "$res/atualizador"
  cp "$MANIFESTO" "$res/atualizador/manifesto.mjs"
  touch "$c/MacOS/TSA" "$res/simulador/x" "$res/gsd/x"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.trafegosa.orca-tsa' \
    -c 'Add :CFBundleShortVersionString string 1.4.197' -c 'Add :CFBundleExecutable string TSA' "$c/Info.plist" >/dev/null
  printf '{"manifest":{"version":"%s","id":"dna-ace-tsa-%s"}}\n' "$DNA_V" "$DNA_C" >"$res/dna-embedded-release.json"
  printf '{\n  "tsa": "%s",\n  "orca": "1.4.197",\n  "commit": "%s",\n  "canal": "aprovada",\n  "gerado_em": "%s",\n  "build_id": "%s"\n}\n' \
    "$VERSAO_REL" "$COMMIT" "$GERADO" "$BUILD_ID" >"$res/tsa-version.json"
  chaves_json tsa-cadu-app-release-v1 "$PEM_ED" >"$res/app-trusted-keys.json"
  RES="$res"
}
# troca um campo do tsa-version.json (valor JSON cru; __apaga__ tira o campo)
campo(){ node -e '
  const fs=require("fs"); const [f,k,v]=process.argv.slice(1); const o=JSON.parse(fs.readFileSync(f,"utf8"))
  if (v==="__apaga__") delete o[k]; else o[k]=JSON.parse(v)
  fs.writeFileSync(f, JSON.stringify(o))' -- "$RES/tsa-version.json" "$1" "$2"; }

# roda confere_app num subshell, como o publicar-release faz depois de montar o DMG
roda(){
  ( export PATH="$WORK/bin:$PATH"; set --
    TSA_PUBLICAR_SO_FUNCOES=1 source "$SCRIPT"
    VERSAO="$VERSAO_REL"; APP_COMMIT="$COMMIT_FULL"; APP_VERSAO="1.4.197"
    POLICY_DNA_VERSAO="$DNA_V"; POLICY_DNA_COMMIT="$DNA_C"
    confere_app "$APPDIR" arm64 ) >"$WORK/saida" 2>&1
}
aceita(){ if roda; then pass "$1"; else fail "$1"; sed 's/^/        /' "$WORK/saida"; fi; }
recusa(){ # nome, trecho esperado na mensagem
  if roda; then fail "$1 (foi aceito)"
  elif grep -qF -- "$2" "$WORK/saida"; then pass "$1"
  else fail "$1 (mensagem inesperada)"; sed 's/^/        /' "$WORK/saida"; fi
}

echo "== sintaxe"
bash -n "$SCRIPT" && pass "bash -n publicar-release.sh" || fail "bash -n publicar-release.sh"

echo "== build:mac recebe a versao da release"
grep -qF 'TSA_ADHOC_SIGN=1 TSA_RELEASE_VERSION="$VERSAO" pnpm run build:mac' "$SCRIPT" &&
  pass "build:mac com TSA_RELEASE_VERSION" || fail "build:mac sem TSA_RELEASE_VERSION"
for r in tsa-version.json app-trusted-keys.json; do
  grep -Eq "^RECURSOS_OBRIGATORIOS=\".*\\b$r\\b" "$SCRIPT" && pass "$r em RECURSOS_OBRIGATORIOS" || fail "$r fora de RECURSOS_OBRIGATORIOS"
done

echo "== TSA.app aceito"
monta ok; aceita "tsa-version.json aprovada, versao e build_id certos"
grep -qF "versao TSA: $VERSAO_REL (aprovada) $BUILD_ID" "$WORK/saida" && pass "ensaio mostra a versao de dentro do DMG" || fail "saida sem a versao"
monta duas; chaves_json tsa-cadu-app-release-v1 "$PEM_ED" outra-v2 "$PEM_ED2" >"$RES/app-trusted-keys.json"
aceita "app-trusted-keys com sucessora a mais"
monta rc; VERSAO_REL=0.9.1-rc.2; campo tsa '"0.9.1-rc.2"'; aceita "versao rc"; VERSAO_REL=0.9.1

echo "== tsa-version.json recusado"
monta sem; rm "$RES/tsa-version.json"; recusa "DMG sem tsa-version.json" "falta Resources/tsa/tsa-version.json"
monta dir; rm "$RES/tsa-version.json"; mkdir -p "$RES/tsa-version.json/x"; recusa "tsa-version.json e pasta" "nao e um arquivo comum"
monta link; mv "$RES/tsa-version.json" "$WORK/fora.json"; ln -s "$WORK/fora.json" "$RES/tsa-version.json"; recusa "tsa-version.json e link" "nao e um arquivo comum"
monta json; printf '{"tsa":' >"$RES/tsa-version.json"; recusa "JSON quebrado" "nao e JSON estrito valido"
monta dup; printf '{"tsa":"0.1.0","tsa":"%s","orca":"1.4.197","commit":"%s","canal":"aprovada","gerado_em":"%s","build_id":"%s"}' "$VERSAO_REL" "$COMMIT" "$GERADO" "$BUILD_ID" >"$RES/tsa-version.json"; recusa "campo repetido" "nao e JSON estrito valido"
monta num; printf '{"tsa":"%s","orca":"1.4.197","commit":"%s","canal":"aprovada","gerado_em":"%s","build_id":"%s","x":1.0}' "$VERSAO_REL" "$COMMIT" "$GERADO" "$BUILD_ID" >"$RES/tsa-version.json"; recusa "numero nao canonico" "nao e JSON estrito valido"
monta utf; printf '{"tsa":"%s","orca":"1.4.197","commit":"%s","canal":"aprovada","gerado_em":"%s","build_id":"%s","x":"\xff"}' "$VERSAO_REL" "$COMMIT" "$GERADO" "$BUILD_ID" >"$RES/tsa-version.json"; recusa "UTF-8 invalido" "nao e JSON estrito valido"
monta semleitor; rm -rf "$RES/atualizador"; recusa "DMG sem o atualizador" "falta Resources/tsa/atualizador"
monta leitorvazio; printf 'export const x = 1\n' >"$RES/atualizador/manifesto.mjs"; recusa "atualizador sem o leitor" "sem lerJsonEstrito"
monta lista; printf '[]\n' >"$RES/tsa-version.json"; recusa "JSON lista" "nao e um objeto"
monta ver; campo tsa '"0.9.0"'; recusa "versao errada" 'diz tsa "0.9.0"; a release e 0.9.1'
monta loc; campo tsa '"0.9.1-local.20260926"'; recusa "versao local" "a release e 0.9.1"
monta canal; campo canal '"local"'; recusa "canal local" 'canal "local"'
monta semcanal; campo canal __apaga__; recusa "sem canal" "canal undefined"
monta semid; campo build_id __apaga__; recusa "sem build_id" "build_id ausente"
monta vazio; campo build_id '""'; recusa "build_id vazio" "build_id ausente"
monta fmt; campo build_id '"ABC123DEF.20260926T010203Z"'; recusa "build_id fora do formato (maiuscula)" "fora do formato"
monta fmt2; campo build_id '"abc123def.20260926T010203"'; recusa "build_id sem Z" "fora do formato"
monta inv; campo build_id '"abc123def.20260926T010204Z"'; recusa "build_id nao bate com gerado_em" "nao bate com commit + gerado_em"
monta com; campo commit '"fff123def"'; campo build_id '"fff123def.20260926T010203Z"'; recusa "commit de outro build" "(dist/ antigo?)"
monta ger; campo gerado_em '"ontem"'; recusa "gerado_em invalido" "gerado_em invalido"
monta fev; campo gerado_em '"2026-02-30T01:02:03.456Z"'; campo build_id '"abc123def.20260302T010203Z"'; recusa "30 de fevereiro (Date normalizaria)" "gerado_em invalido"
monta bis; campo gerado_em '"2025-02-29T01:02:03.456Z"'; campo build_id '"abc123def.20250301T010203Z"'; recusa "29/02 em ano nao bissexto" "gerado_em invalido"
monta ms; campo gerado_em '"2026-09-26T01:02:03Z"'; recusa "gerado_em sem milissegundos" "gerado_em invalido"
monta bis2; campo gerado_em '"2028-02-29T01:02:03.456Z"'; campo build_id '"abc123def.20280229T010203Z"'; aceita "29/02 em ano bissexto"

echo "== app-trusted-keys.json recusado"
monta ksem; rm "$RES/app-trusted-keys.json"; recusa "sem app-trusted-keys.json" "falta Resources/tsa/app-trusted-keys.json"
monta kv1; printf '{"format":"tsa.app.trusted-keys/v1","keys":[]}\n' >"$RES/app-trusted-keys.json"; recusa "formato antigo v1" "sem a chave tsa-cadu-app-release-v1"
monta klista; printf '[]\n' >"$RES/app-trusted-keys.json"; recusa "lista" "nao e um objeto"
monta kdup; printf '{"tsa-cadu-app-release-v1":"x","tsa-cadu-app-release-v1":%s}' "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$PEM_ED")" >"$RES/app-trusted-keys.json"; recusa "key_id repetido" "nao e JSON estrito valido"
monta kesc; printf '{"tsa-cadu-app-release-v1":%s,"tsa-cadu-app-release-\\u0076\\u0031":%s}' "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$PEM_ED")" "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$PEM_ED2")" >"$RES/app-trusted-keys.json"; recusa "key_id repetido por escape unicode" "nao e JSON estrito valido"
monta kout; chaves_json outra-v2 "$PEM_ED" >"$RES/app-trusted-keys.json"; recusa "sem a chave da F1" "sem a chave tsa-cadu-app-release-v1"
monta krsa; chaves_json tsa-cadu-app-release-v1 "$PEM_RSA" >"$RES/app-trusted-keys.json"; recusa "chave RSA" "nao e um PEM Ed25519 exato"
monta klixo; chaves_json tsa-cadu-app-release-v1 "nao e pem" >"$RES/app-trusted-keys.json"; recusa "valor que nao e PEM" "nao e um PEM Ed25519 exato"
monta kextra; chaves_json tsa-cadu-app-release-v1 "$PEM_ED" ruim "x" >"$RES/app-trusted-keys.json"; recusa "chave extra invalida" '"ruim" nao e um PEM Ed25519 exato'
monta knl; chaves_json tsa-cadu-app-release-v1 "${PEM_ED%$'\n'}" >"$RES/app-trusted-keys.json"; recusa "PEM sem quebra de linha no fim" "nao e um PEM Ed25519 exato"
monta k2pem; chaves_json tsa-cadu-app-release-v1 "$PEM_ED$PEM_ED2" >"$RES/app-trusted-keys.json"; recusa "dois PEMs concatenados" "nao e um PEM Ed25519 exato"
monta kid; chaves_json tsa-cadu-app-release-v1 "$PEM_ED" "BAD KEY" "$PEM_ED2" >"$RES/app-trusted-keys.json"; recusa "key_id invalido a mais" 'key_id fora do formato: "BAD KEY"'
monta kvazio; chaves_json tsa-cadu-app-release-v1 "$PEM_ED" "" "$PEM_ED2" >"$RES/app-trusted-keys.json"; recusa "key_id vazio" 'key_id fora do formato: ""'


echo "== zip igual ao DMG"
# zip do app correto (mesmo formato do electron-builder: TSA.app/ na raiz)
zipa(){ rm -f "$WORK/app.zip"; ( cd "$(dirname "$APPDIR")" && /usr/bin/zip -qry "$WORK/app.zip" TSA.app ); }
rodazip(){ # pasta de referencia (DMG conferido)
  # set --: o laco de opcoes do script consumiria os argumentos desta funcao
  ( ref="$1"; set --; export PATH="$WORK/bin:$PATH"
    TSA_PUBLICAR_SO_FUNCOES=1 source "$SCRIPT"
    VERSAO="$VERSAO_REL"; APP_COMMIT="$COMMIT_FULL"; APP_VERSAO="1.4.197"
    POLICY_DNA_VERSAO="$DNA_V"; POLICY_DNA_COMMIT="$DNA_C"
    confere_zip "$WORK/app.zip" "$ref" arm64 "$WORK/extraido zip" ) >"$WORK/saida" 2>&1
}
zaceita(){ if rodazip "$2"; then pass "$1"; else fail "$1"; sed 's/^/        /' "$WORK/saida"; fi; }
zrecusa(){ if rodazip "$3"; then fail "$1 (foi aceito)"
  elif grep -qF -- "$2" "$WORK/saida"; then pass "$1"
  else fail "$1 (mensagem inesperada)"; sed 's/^/        /' "$WORK/saida"; fi; }
monta dmg; REF="$RES"
monta z1; zipa; zaceita "zip igual ao DMG" "$REF"
grep -qF "versao TSA: $VERSAO_REL (aprovada) $BUILD_ID" "$WORK/saida" && pass "app do zip passa pelo confere_app" || fail "app do zip sem confere_app"
[ ! -e "$WORK/extraido zip" ] && pass "pasta de extracao apagada" || fail "pasta de extracao ficou"
monta z2; campo tsa '"0.9.0"'; zipa; zrecusa "zip com outra versao" "zip arm64: tsa-version.json diz tsa \"0.9.0\"" "$REF"
monta z3; chaves_json tsa-cadu-app-release-v1 "$PEM_ED2" >"$RES/app-trusted-keys.json"; zipa; zrecusa "zip com outra chave" "app-trusted-keys.json do zip arm64 difere" "$REF"
monta z4; mv "$RES/tsa-version.json" "$RES/tsa-version.json.bak"; zipa; zrecusa "zip so com tsa-version.json.bak" "falta Resources/tsa/tsa-version.json no zip arm64" "$REF"
monta z5; mv "$RES/app-trusted-keys.json" "$RES/app-trusted-keys.json.bak"; zipa; zrecusa "zip so com app-trusted-keys.json.bak" "falta Resources/tsa/app-trusted-keys.json no zip arm64" "$REF"
monta z6; mv "$RES/atualizador" "$RES/atualizador-backup"; zipa; zrecusa "zip so com atualizador-backup/" "falta Resources/tsa/atualizador no zip arm64" "$REF"
monta z7; printf '// outro\n' >>"$RES/atualizador/manifesto.mjs"; zipa; zrecusa "zip com outro leitor" "atualizador/manifesto.mjs do zip arm64 difere" "$REF"
monta z8; mkdir -p "$WORK/caso z8/Outro.app/Contents"; cp "$APPDIR/Contents/Info.plist" "$WORK/caso z8/Outro.app/Contents/"
  rm -f "$WORK/app.zip"; ( cd "$WORK/caso z8" && /usr/bin/zip -qry "$WORK/app.zip" TSA.app Outro.app ); zrecusa "zip com dois apps" "nao tem exatamente um .app" "$REF"
monta z9; mkdir -p "$WORK/caso z9/Outro.app/Contents/MacOS"; touch "$WORK/caso z9/Outro.app/Contents/MacOS/Outro"
  rm -f "$WORK/app.zip"; ( cd "$WORK/caso z9" && /usr/bin/zip -qry "$WORK/app.zip" TSA.app Outro.app ); zrecusa "zip com segundo app sem Info.plist" "nao tem exatamente um .app" "$REF"
monta z10; printf 'x\n' >"$WORK/caso z10/LEIAME"
  rm -f "$WORK/app.zip"; ( cd "$WORK/caso z10" && /usr/bin/zip -qry "$WORK/app.zip" TSA.app LEIAME ); zrecusa "zip com arquivo fora do app" "nada fora dele" "$REF"
# tsa-version.json em duas entradas com metade do arquivo cada: juntas, dariam o arquivo certo
monta z11; zipa; /usr/bin/python3 - "$WORK/app.zip" "$RES/tsa-version.json" <<'PY' 2>/dev/null
import sys, zipfile
z, f = sys.argv[1], sys.argv[2]
d = open(f, 'rb').read(); n = 'TSA.app/Contents/Resources/tsa/tsa-version.json'
src = zipfile.ZipFile(z); itens = [(i, src.read(i)) for i in src.infolist() if i.filename != n]; src.close()
with zipfile.ZipFile(z, 'w') as out:
    for i, b in itens: out.writestr(i, b)
    out.writestr(n, d[:len(d)//2]); out.writestr(n, d[len(d)//2:])
PY
zrecusa "zip com tsa-version.json partido em duas entradas" "nome repetido" "$REF"
# acrescenta ao zip do app certo uma entrada com outro nome que cai no mesmo arquivo ao extrair
extra(){ # nome da entrada, conteudo
  /usr/bin/python3 - "$WORK/app.zip" "$1" "$2" <<'PY' 2>/dev/null
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as z: z.writestr(sys.argv[2], sys.argv[3])
PY
}
monta z12; zipa; extra "TSA.app/Contents/Resources/tsa/TSA-VERSION.JSON" '{"tsa":"0.0.1"}'; zrecusa "zip com o mesmo nome em outra caixa" "nome repetido" "$REF"
monta z13; zipa; extra "TSA.app/Contents/Resources/tsa/./tsa-version.json" '{}'; zrecusa "zip com ./ no caminho" "caminho nao canonico" "$REF"
monta z14; zipa; extra "TSA.app/Contents/Resources/tsa//tsa-version.json" '{}'; zrecusa "zip com // no caminho" "caminho nao canonico" "$REF"
monta z15; zipa; extra "TSA.app/Contents/../../fora" 'x'; zrecusa "zip com ../ no caminho" "caminho nao canonico" "$REF"
monta z16; zipa; extra "TSA.app/Contents/Resources/tsa\\tsa-version.json" '{}'; zrecusa "zip com barra invertida" "caminho nao canonico" "$REF"
# listagem grande com o Info.plist no comeco: nada de SIGPIPE recusando zip bom (WO10-CX-08)
monta z17; mkdir -p "$APPDIR/Contents/Resources/muitos"; ( cd "$APPDIR/Contents/Resources/muitos" && for i in $(seq 1 2500); do : >"arquivo-$i"; done )
  zipa; zaceita "zip com 2500 entradas" "$REF"

echo
echo "$PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
