#!/bin/bash
# Testa o instalador do painel, docs/instalartsa/install.sh e atualizar.sh (WO-18;
# INSTALAR-F2-CONTRATO v2.0, seções 4.5, 7 e 8.6), sem rede, sem /Applications real e sem as
# Chaves reais:
# - verificador no osascript de verdade: os 8 vetores do app, os 3 de leitura estrita (§7.3,
#   regra 5) e o manifesto real de 02/10/2026 com as chaves reais; chaves do script iguais
#   byte a byte às do app;
# - casos A, B1, B2 e C e a troca interrompida, com curl, hdiutil, codesign, ditto, xattr,
#   open e security falsos (o security guarda os itens em arquivos do teste);
# - T-INS-25: convite e credencial nunca em argumento de processo.
# Os manifestos dos casos são assinados por uma chave só de teste; o teste roda uma cópia do
# install.sh com essa chave no lugar das reais (o script de produção não aceita chave de fora).
#   bash scripts/test-instalartsa.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docs/instalartsa/install.sh"
ATUALIZAR="$ROOT/docs/instalartsa/atualizar.sh"
TSA_APP_DIR="${TSA_APP_DIR:-$ROOT/../tsa-app}"
CHAVES_APP="$TSA_APP_DIR/resources/tsa/app-trusted-keys.json"
VETORES="$TSA_APP_DIR/resources/tsa/atualizador/vetores-manifesto.json"
MANIFESTO_MJS="$TSA_APP_DIR/resources/tsa/atualizador/manifesto.mjs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsa-instalartsa-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check(){
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok     $1"
  else FAIL=$((FAIL + 1)); echo "  FALHOU $1"; [ -n "${S:-}" ] && sed 's/^/       | /' "$S"/out* 2>/dev/null; fi
}
for f in "$CHAVES_APP" "$VETORES" "$MANIFESTO_MJS"; do
  [ -f "$f" ] || { echo "falta $f (worktree tsa-app ao lado do instalador)"; exit 1; }
done

# ---------------------------------------------------------------- verificador
# Os blocos de JavaScript saem do próprio install.sh: o teste roda o texto que vai para o time.
bloco(){ awk -v f="$1(){ cat <<'$2'" '$0==f{on=1;next} on&&$0=="'"$2"'"{exit} on' "$SCRIPT"; }
V="$WORK/verificador.js"; LT="$WORK/leitor.js"
{ bloco js_json JS; bloco js_verificador JS; } >"$V"
{ bloco js_json JS; bloco js_leitor JS; } >"$LT"
verifica(){ /usr/bin/osascript -l JavaScript "$V" verificar "$1" "$2" 2>&1; }

echo "1. chaves fixadas no install.sh iguais byte a byte às do app"
bloco chaves_confiaveis JSON >"$WORK/chaves-script.json"
check "cmp com tsa-app/resources/tsa/app-trusted-keys.json" 'cmp -s "$WORK/chaves-script.json" "$CHAVES_APP"'

echo "2. os 8 vetores do app (vetores-manifesto.json) no osascript"
mkdir -p "$WORK/vet"
python3 - "$VETORES" "$WORK/vet" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1])); o = sys.argv[2]
json.dump(d['chaves_confiaveis'], open(os.path.join(o, 'chaves.json'), 'w'))
for v in d['vetores']:
    # Vetor de leitura estrita guarda o texto cru (a WO-19 acrescenta com manifesto_texto).
    texto = v['manifesto_texto'] if 'manifesto_texto' in v else json.dumps(v['manifesto'])
    open(os.path.join(o, v['nome'] + '.json'), 'w').write(texto)
    e = dict(v['esperado']); e.pop('campo', None) if e.get('motivo') != 'manifesto_invalido' else None
    if e.get('ok'): e['hash'] = v['hash']
    open(os.path.join(o, v['nome'] + '.esperado'), 'w').write(json.dumps(e))
PY
confere(){ # saída do verificador, arquivo com o esperado
  python3 -c '
import json,sys
r=json.loads(sys.argv[1]); e=json.load(open(sys.argv[2]))
sys.exit(0 if all(r.get(k)==v for k,v in e.items()) else 1)' "$1" "$2"
}
n=0
for e in "$WORK"/vet/*.esperado; do
  nome="$(basename "$e" .esperado)"; n=$((n + 1))
  r="$(verifica "$WORK/vet/$nome.json" "$WORK/vet/chaves.json")"
  check "vetor $nome" 'confere "$r" "$e"'
done
check "pelo menos os 8 vetores do app (os 3 estritos entram quando a WO-19 os acrescentar)" '[ $n -ge 8 ]'

echo "3. leitura estrita: os 3 vetores novos (§7.3, regra 5)"
DMG="$WORK/dmg.bin"; head -c 5000 /dev/urandom >"$DMG"
DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"; DMG_BYTES="$(stat -f %z "$DMG")"
NOVO_ID="49d050c9f.20261002T135453Z"
mkdir -p "$WORK/ass"
node "$ROOT/scripts/fixtures/assinar-teste.mjs" "$MANIFESTO_MJS" "$WORK/ass" "$DMG_SHA" "$DMG_BYTES" "$NOVO_ID" ||
  { echo "falha ao gerar os manifestos de teste"; exit 1; }
for x in chave-repetida bytes-ponto bytes-expoente; do
  r="$(verifica "$WORK/ass/estrito-$x.json" "$WORK/ass/chaves.json")"
  check "$x reprova como manifesto_invalido" '[[ "$r" == *"\"motivo\":\"manifesto_invalido\""* ]]'
  m="$(node -e 'import(process.argv[1]).then(m=>{const fs=require("fs");const t=fs.readFileSync(process.argv[2],"utf8");let r;try{r=m.verificarManifesto(m.lerJsonEstrito(t),JSON.parse(fs.readFileSync(process.argv[3],"utf8")))}catch{r={ok:false,motivo:"manifesto_invalido"}};console.log(r.motivo||"ok")})' \
    "$MANIFESTO_MJS" "$WORK/ass/estrito-$x.json" "$WORK/ass/chaves.json" 2>/dev/null)"
  check "$x também reprova no manifesto.mjs" '[ "$m" = manifesto_invalido ]'
done
r="$(verifica "$WORK/ass/valido.json" "$WORK/ass/chaves.json")"
check "manifesto de teste válido aprova" '[[ "$r" == "{\"ok\":true,"* ]]'
r="$(verifica "$WORK/ass/adulterado.json" "$WORK/ass/chaves.json")"
check "adulterado depois de assinar: assinatura_invalida" '[[ "$r" == *assinatura_invalida* ]]'

echo "3b. chave extra com ponto inválido no arquivo: mesmo veredito do manifesto.mjs"
python3 - "$WORK/ass/chaves.json" "$WORK/chaves-ponto.json" <<'PY2'
import json, sys, base64
k = json.load(open(sys.argv[1]))
# y = p - 1 dá x = 0; com o bit de sinal ligado não decodifica (RFC 8032 5.1.3), mas o PEM é
# estruturalmente válido
y = ((2**255 - 19 - 1) | (1 << 255)).to_bytes(32, 'little')
der = bytes.fromhex('302a300506032b6570032100') + y
k['tsa-ponto-ruim'] = '-----BEGIN PUBLIC KEY-----\n' + base64.b64encode(der).decode() + '\n-----END PUBLIC KEY-----\n'
json.dump(k, open(sys.argv[2], 'w'))
PY2
r="$(verifica "$WORK/ass/valido.json" "$WORK/chaves-ponto.json")"
m="$(node -e 'import(process.argv[1]).then(m=>{const fs=require("fs");const r=m.verificarManifesto(m.lerJsonEstrito(fs.readFileSync(process.argv[2])),JSON.parse(fs.readFileSync(process.argv[3],"utf8")));console.log(r.ok?"ok":r.motivo)})' \
  "$MANIFESTO_MJS" "$WORK/ass/valido.json" "$WORK/chaves-ponto.json" 2>/dev/null)"
check "a chave extra não decodifica como ponto" 'python3 -c "
import json,base64,sys
d=base64.b64decode(json.load(open(sys.argv[1]))[\"tsa-ponto-ruim\"].split(chr(10))[1])[12:]
sys.exit(0 if d[31]>>7==1 and int.from_bytes(d,\"little\")&((1<<255)-1)==2**255-20 else 1)" "$WORK/chaves-ponto.json"'
check "osascript e manifesto.mjs dão o mesmo veredito ($m)" '[ "$m" = ok ] && [[ "$r" == "{\"ok\":true,"* ]] || { [ "$m" != ok ] && [[ "$r" == *"$m"* ]]; }'

echo "4. manifesto real de 02/10/2026 com as chaves reais"
REAL="$ROOT/scripts/fixtures/manifesto-real-20261002.json"
r="$(verifica "$REAL" "$CHAVES_APP")"
check "aceito, com o hash que o publicar-na-central assinou" \
  '[ "$r" = "{\"ok\":true,\"hash\":\"b45eae07d968b40e92729e05d378e66ccefc39147b7b54269939d4251275d35f\",\"key_id\":\"tsa-cadu-app-release-v1\"}" ]'
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));m["notas"]+="x";json.dump(m,open(sys.argv[2],"w"))' "$REAL" "$WORK/real-mexido.json"
r="$(verifica "$WORK/real-mexido.json" "$CHAVES_APP")"
check "com um caractere a mais em notas: assinatura_invalida" '[[ "$r" == *assinatura_invalida* ]]'
r="$(verifica "$REAL" "$WORK/ass/chaves.json")"
check "com a chave errada: chave_desconhecida" '[[ "$r" == *chave_desconhecida* ]]'

# ---------------------------------------------------------------- casos do install.sh
# Cópia do script com a chave de teste no lugar das reais.
TESTE_SCRIPT="$WORK/install-teste.sh"
awk -v k="$WORK/ass/chaves.json" '
  $0=="chaves_confiaveis(){ cat <<'"'"'JSON'"'"'" {print; while((getline l < k)>0) print l; skip=1; next}
  skip && $0=="JSON" {skip=0}
  !skip {print}' "$SCRIPT" >"$TESTE_SCRIPT"

FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
fake(){ printf '#!/bin/bash\n%s\n' "$2" >"$FAKE/$1"; chmod +x "$FAKE/$1"; }
# curl falso: lê o --config da entrada padrão, registra o argv (que não pode ter segredo) e
# o config (por onde o segredo deve passar) e responde pela rota.
fake curl '
echo "curl $*" >>"$FAKE_LOG"
[ "$1" = -q ] || { echo "SEM -q" >>"$FAKE_LOG"; exit 2; }
cfg="$(cat)"; printf "%s\n---\n" "$cfg" >>"$FAKE_CFG"
v(){ printf "%s\n" "$cfg" | sed -n "s/^$1 = \"\\(.*\\)\"\$/\\1/p" | head -1; }
url="$(v url)"; out="$(v output)"
resp(){ printf "%s" "$2" >"$out"; printf "%s" "$1"; }
case "$url" in
  */convite/validar)
    c="${FAKE_VALIDAR:-200}"
    if [ -n "${FAKE_VALIDAR_1:-}" ] && [ ! -e "$FAKE_DIR/validou1" ]; then touch "$FAKE_DIR/validou1"; c="$FAKE_VALIDAR_1"; fi
    case "$c" in
      200) resp 200 "{\"valido\":true,\"expira_em\":\"2026-10-03T14:00:00Z\",\"perfil_sugerido\":null}" ;;
      410) resp 410 "{\"error\":\"convite_usado\"}" ;;
      *) resp "$c" "{\"error\":\"convite_invalido\"}" ;;
    esac ;;
  */release/nova-instalacao|*/v1/app/release\?*)
    n=$(( $(cat "$FAKE_DIR/pedidos" 2>/dev/null || echo 0) + 1 )); echo $n >"$FAKE_DIR/pedidos"
    [ -n "${FAKE_RELEASE:-}" ] && { resp "$FAKE_RELEASE" ""; exit 0; }
    m="$FAKE_DIR/manifesto.json"; [ "$n" -ge 2 ] && [ -n "${FAKE_MANIFESTO_2:-}" ] && m="$FAKE_MANIFESTO_2"
    resp 200 "{\"manifesto\":$(cat "$m"),\"origem\":\"ativa\",\"teste\":false}" ;;
  */artefatos/*)
    # FAKE_CORTE: a 1a transferência cai na metade (HTTP 200, retorno 18); a seguinte retoma
    # por Range (continue-at) e manda só o resto, com 206.
    tam=$(stat -f %z "$FAKE_DMG_SERVIDO")
    if [ -n "${FAKE_CORTE:-}" ] && [ ! -e "$FAKE_DIR/cortou" ]; then
      touch "$FAKE_DIR/cortou"; head -c $((tam / 2)) "$FAKE_DMG_SERVIDO" >"$out"; printf 200; exit 18
    fi
    if [ "$(v continue-at)" = "-" ] && [ -s "$out" ]; then
      ja=$(stat -f %z "$out"); echo "retomou $ja" >>"$FAKE_LOG"
      tail -c +$((ja + 1)) "$FAKE_DMG_SERVIDO" >>"$out"; printf 206
    else cp "$FAKE_DMG_SERVIDO" "$out"; printf 200; fi ;;
  *) printf 404 ;;
esac'
fake hdiutil '
echo "hdiutil $*" >>"$FAKE_LOG"
case "$1" in
  attach)
    A="$FAKE_VOLUME/TSA.app/Contents"; mkdir -p "$A/MacOS" "$A/Resources/tsa"; echo bin >"$A/MacOS/TSA"
    printf "{\"tsa\":\"0.5.0\",\"build_id\":\"%s\"}\n" "$FAKE_BUILD_DMG" >"$A/Resources/tsa/tsa-version.json"
    /usr/bin/plutil -create xml1 "$A/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "${FAKE_BUNDLE_ID:-com.trafegosa.orca-tsa}" "$A/Info.plist"
    printf "/dev/disk9\tGUID_partition_scheme\t\n/dev/disk9s1\tApple_HFS\t%s\n" "$FAKE_VOLUME" ;;
esac
exit 0'
fake codesign 'echo "codesign $*" >>"$FAKE_LOG"; a="${@: -1}"; [ -f "$a/Contents/MacOS/TSA" ]'
fake ditto 'echo "ditto $*" >>"$FAKE_LOG"; cp -R "$1" "$2"'
fake xattr 'exit 0'
fake open 'echo "open $*" >>"$FAKE_LOG"'
# security falso: itens em arquivos; o -i lê o comando da entrada padrão.
fake security '
echo "security $*" >>"$FAKE_LOG"
item(){ printf "%s/%s__%s" "$FAKE_DIR/chaves" "$1" "$2"; }
opera(){
  local s="" a="" w="" verbo="$1" mostrar=0; shift
  while [ $# -gt 0 ]; do case "$1" in -s) s="$2"; shift 2;; -a) a="$2"; shift 2;; -w) if [ "$verbo" = add-generic-password ]; then w="$2"; shift 2; else mostrar=1; shift; fi;; *) shift;; esac; done
  mkdir -p "$FAKE_DIR/chaves"
  case "$verbo" in
    add-generic-password) printf "%s" "$w" >"$(item "$s" "$a")" ;;
    find-generic-password) [ -f "$(item "$s" "$a")" ] || return 44; [ $mostrar = 1 ] && cat "$(item "$s" "$a")"; return 0 ;;
    delete-generic-password) rm -f "$(item "$s" "$a")" ;;
  esac
}
if [ "${1:-}" = -i ]; then while read -r -a l; do opera "${l[@]}"; done; exit 0; fi
opera "$@"'

ANTES="$WORK/antes"; mkdir -p "$ANTES"
CONVITE="Cv0nv1te_de-teste_0123456789abcdefghijKLMNO"
CRED="Cr3dencial_de-teste_0123456789abcdefghijKLM"
UUID="1263da3d-dbf3-46ac-a49c-ea76340fd826"

setup(){ # nome, extras: app cadastrada estado_troca
  S="$WORK/c-$1"; rm -rf "$S"; mkdir -p "$S/home" "$S/Applications" "$S/fake"; RUNS=0
  : >"$S/log"; : >"$S/cfg"
  cp "$WORK/ass/valido.json" "$S/fake/manifesto.json"
  local b; shift
  for b in "$@"; do case "$b" in
    app) mkdir -p "$S/Applications/TSA.app/Contents/MacOS"; echo velho >"$S/Applications/TSA.app/Contents/MacOS/TSA" ;;
    cadastrada)
      mkdir -p "$S/home/Library/Application Support/TSA/atualizador" "$S/fake/chaves"
      printf '{ "installation_id": "%s", "api": "https://ace.acetsia.com/inteligencia" }\n' "$UUID" \
        >"$S/home/Library/Application Support/TSA/atualizador/instalacao.json"
      printf '%s' "$CRED" >"$S/fake/chaves/tsa-atualizador__$UUID" ;;
    perfil) printf '{ "perfil": "gestao" }\n' >"$S/home/Library/Application Support/TSA/perfil.json" ;;
    atualizador) # agendador falso: registra o modo; no --retomar conclui a troca; no --agora grava o resumo
      cat >"$S/home/Library/Application Support/TSA/atualizador/atualizar.sh" <<EOF2
#!/bin/bash
echo "atualizar.sh \$*" >>"$S/log"
if [ "\$1" = --retomar ] && [ -n "\${FAKE_RETOMAR_ILEGIVEL:-}" ]; then printf '{"troca":' >"$S/home/Library/Application Support/TSA/atualizacao/estado.json"; exit 0; fi
if [ "\$1" = --retomar ] && [ -z "\${FAKE_RETOMAR_FALHA:-}" ]; then printf '{"troca":null,"pedidos_tratados":[]}\n' >"$S/home/Library/Application Support/TSA/atualizacao/estado.json"; fi
if [ "\$1" = --agora ]; then
  [ -n "\${FAKE_AGORA_RC:-}" ] && exit "\$FAKE_AGORA_RC"
  [ -n "\${FAKE_SEM_RESUMO:-}" ] && exit 0
  mkdir -p "$S/home/Library/Logs/TSA"; printf '{"schema":"tsa.atualizacao.resumo/v1","estado":"sem_novidade"}\n' >"$S/home/Library/Logs/TSA/atualizar-auto-ultimo.json"
fi
exit 0
EOF2
      ;;
    troca) # estado.json completo do contrato §8.4, com listas
      mkdir -p "$S/home/Library/Application Support/TSA/atualizacao"
      printf '{"schema":"tsa.atualizacao.estado/v1","estado":"trocando","desde":"2026-10-02T03:00:00Z","atualizado_em":"2026-10-02T03:00:05Z","motivo":null,"versao_alvo":"0.5.0","build_id_alvo":"49d050c9f.20261002T135453Z","pendente_desde":null,"nao_antes_de":null,"agora_nao_usado":false,"depois_usado":false,"pergunta_em":null,"pergunta_aberta":false,"aviso":null,"fechamento":null,"troca":{"tentativa_id":"6f1c2b9e-1111-4222-8333-944455556666","terminais":[{"workspace":"ACE Master","terminal":"t1","agente":null,"estado":null}]},"voltou_build_id":null,"preparo_sha256":null,"pedidos_tratados":["a","b"],"ultimo_resumo_valido":null}\n' \
        >"$S/home/Library/Application Support/TSA/atualizacao/estado.json" ;;
  esac; done
}
run(){ # tty (texto), argumentos do install.sh e variáveis
  RUNS=$((RUNS + 1)); OUT="$S/out$RUNS"
  local tty="$S/tty$RUNS"; printf '%b' "$1" >"$tty"; shift
  local args=() envs=()
  while [ $# -gt 0 ]; do case "$1" in --*) args+=("$1"); [ "$1" = --perfil ] && { args+=("$2"); shift; }; shift ;; *) envs+=("$1"); shift ;; esac; done
  # vigia contra travamento: 60 s por execução
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 env -i HOME="$S/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$WORK" \
    FAKE_LOG="$S/log" FAKE_CFG="$S/cfg" FAKE_DIR="$S/fake" FAKE_VOLUME="$S/volume" \
    FAKE_BUILD_DMG="$NOVO_ID" FAKE_DMG_SERVIDO="$DMG" \
    TSA_PAINEL_API="https://painel.invalido/apptsa/api" TSA_APP_DEST="$S/Applications" TSA_TTY="$tty" \
    TSA_CURL="$FAKE/curl" TSA_HDIUTIL="$FAKE/hdiutil" TSA_CODESIGN="$FAKE/codesign" TSA_DITTO="$FAKE/ditto" \
    TSA_XATTR="$FAKE/xattr" TSA_OPEN="$FAKE/open" TSA_SECURITY="$FAKE/security" TSA_SKIP_PREREQS=1 \
    ${envs[@]+"${envs[@]}"} /bin/bash "$TESTE_SCRIPT" ${args[@]+"${args[@]}"} >"$OUT" 2>&1
  RC=$?
}
out_has(){ grep -qF "$1" "$OUT"; }
TSA_DIR(){ printf '%s' "$S/home/Library/Application Support/TSA"; }
instalado(){ [ -f "$S/Applications/TSA.app/Contents/Resources/tsa/tsa-version.json" ] && grep -q "$NOVO_ID" "$S/Applications/TSA.app/Contents/Resources/tsa/tsa-version.json"; }
nada_instalado(){ [ ! -e "$S/Applications/TSA.app" ] && [ ! -e "$S/Applications/.TSA-novo.app" ]; }
sem_segredo_em_argumento(){ ! grep -qF "$CONVITE" "$S/log" && ! grep -qF "$CRED" "$S/log"; }
baixou(){ grep -q 'artefatos' "$S/cfg"; }

echo "5. caso A: instalação nova"
setup a
run "$CONVITE\n1\n"
check "sai 0" '[ $RC = 0 ]'
check "instala o app do manifesto" 'instalado && [ ! -e "$S/Applications/.TSA-novo.app" ]'
check "grava o setor escolhido" 'grep -q "\"perfil\": \"trafego\"" "$(TSA_DIR)/perfil.json"'
check "entrega o convite ao Chaves (tsa-convite-pendente)" '[ "$(cat "$S/fake/chaves/tsa-convite-pendente__convite")" = "$CONVITE" ]'
check "T-INS-25: convite nunca em argumento (curl e security)" 'sem_segredo_em_argumento'
check "o convite passa pela entrada padrão do curl" 'grep -qF "$CONVITE" "$S/cfg"'
check "o curl só recebe -q --config - (sem ~/.curlrc)" '! grep "^curl " "$S/log" | grep -qv "^curl -q --config -$" && ! grep -q "SEM -q" "$S/log"'
check "modos: pastas 0700 (inclusive a de logs criada) e perfil.json 0600" \
  '[ "$(stat -f %Lp "$S/home/Library/Logs/TSA")" = 700 ] && [ "$(stat -f %Lp "$(TSA_DIR)")" = 700 ] && [ "$(stat -f %Lp "$(TSA_DIR)/atualizador")" = 700 ] && [ "$(stat -f %Lp "$(TSA_DIR)/perfil.json")" = 600 ]'
check "confere o pacote: hdiutil verify e codesign" 'grep -q "^hdiutil verify" "$S/log" && grep -q "^codesign --verify --deep --strict" "$S/log"'
check "reconsulta o manifesto antes de instalar" '[ "$(cat "$S/fake/pedidos")" = 2 ]'
check "sem marca sem-agendador" '[ ! -e "$(TSA_DIR)/atualizador/sem-agendador" ]'
check "abre o TSA e diz que o cadastro termina sozinho" 'grep -q "^open $S/Applications/TSA.app" "$S/log" && out_has "terminar o cadastro sozinho"'
check "não grava instalacao.json nem credencial (quem cadastra é o app)" '[ ! -e "$(TSA_DIR)/atualizador/instalacao.json" ] && [ ! -e "$S/fake/chaves/tsa-atualizador__$UUID" ]'

echo "6. caso A com --perfil e --sem-agendador"
setup aperfil
run "$CONVITE\n" --perfil gestao --sem-agendador
check "sai 0 sem perguntar o setor" '[ $RC = 0 ] && ! out_has "Qual é o seu setor" && grep -q gestao "$(TSA_DIR)/perfil.json"'
check "cria a marca sem-agendador, 0600" '[ "$(stat -f %Lp "$(TSA_DIR)/atualizador/sem-agendador")" = 600 ]'

echo "6b. --perfil fora da lista ou composto"
setup acomp; run "$CONVITE\n" --perfil "trafego audiovisual"
check "recusa \"trafego audiovisual\" sem chamar a Central" '[ $RC != 0 ] && ! grep -q "^curl" "$S/log"'
setup acomp2; run "$CONVITE\n" --perfil copy
check "recusa o id antigo copy" '[ $RC != 0 ] && ! grep -q "^curl" "$S/log"'

echo "6c. download que cai no meio é retomado"
setup acorte; run "$CONVITE\n1\n" FAKE_CORTE=1 TSA_ESPERA_DOWNLOAD=0
check "retoma por Range e instala" '[ $RC = 0 ] && grep -q "^retomou " "$S/log" && instalado'

echo "7. convite com formato errado e depois certo; setor fora da lista"
setup adigita
run "curto\n$CONVITE\n9\n3\n"
check "sai 0, pede de novo e grava copy-criativos" '[ $RC = 0 ] && out_has "43 caracteres" && grep -q copy-criativos "$(TSA_DIR)/perfil.json"'

echo "8. convite usado (410)"
setup ausado; run "$CONVITE\n" FAKE_VALIDAR=410
check "para com a mensagem, sem baixar nem instalar" '[ $RC != 0 ] && out_has "já foi usado" && ! baixou && nada_instalado'

echo "9. três convites desconhecidos (401)"
setup a401; run "$CONVITE\n$CONVITE\n$CONVITE\n" FAKE_VALIDAR=401
check "para depois de três tentativas, sem baixar" '[ $RC != 0 ] && out_has "Três tentativas" && ! baixou && nada_instalado'

echo "10. manifesto adulterado"
setup aadult; cp "$WORK/ass/adulterado.json" "$S/fake/manifesto.json"; run "$CONVITE\n1\n"
check "para antes de baixar e não instala" '[ $RC != 0 ] && out_has "não passou na conferência" && ! baixou && nada_instalado'
check "não entrega o convite" '[ ! -e "$S/fake/chaves/tsa-convite-pendente__convite" ]'

echo "11. manifesto com chave repetida dentro da resposta"
setup arep; cp "$WORK/ass/estrito-chave-repetida.json" "$S/fake/manifesto.json"; run "$CONVITE\n1\n"
check "para antes de baixar" '[ $RC != 0 ] && ! baixou && nada_instalado'

echo "12. DMG diferente do manifesto"
setup asha; head -c 5000 /dev/zero >"$WORK/dmg-errado.bin"; run "$CONVITE\n1\n" FAKE_DMG_SERVIDO="$WORK/dmg-errado.bin"
check "para, apaga o download e não instala" '[ $RC != 0 ] && out_has "não passou na conferência" && nada_instalado'

echo "13. DMG com outro build_id ou outro bundle id"
setup abuild; run "$CONVITE\n1\n" FAKE_BUILD_DMG=abc1234.20200101T000000Z
check "build_id diferente: não instala" '[ $RC != 0 ] && nada_instalado'
setup abundle; run "$CONVITE\n1\n" FAKE_BUNDLE_ID=com.outro.app
check "bundle id diferente: não instala" '[ $RC != 0 ] && nada_instalado'

echo "14. a release muda durante o download (reconsulta)"
setup amuda
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));m["build_id"]="abcdef0.20261003T000000Z";json.dump(m,open(sys.argv[2],"w"))' \
  "$WORK/ass/valido.json" "$S/fake/manifesto-2.json"
run "$CONVITE\n1\n" FAKE_MANIFESTO_2="$S/fake/manifesto-2.json"
check "para sem instalar" '[ $RC != 0 ] && out_has "mudou durante o download" && nada_instalado'

echo "15. nenhuma versão liberada (204)"
setup a204; run "$CONVITE\n1\n" FAKE_RELEASE=204
check "para com a mensagem, sem instalar" '[ $RC != 0 ] && out_has "Ainda não há versão liberada" && nada_instalado'

echo "16. sem terminal"
setup atty; run "" TSA_TTY=/nao/existe
check "para sem pedir convite por outro meio" '[ $RC != 0 ] && out_has "precisa de um terminal" && ! grep -q "^curl" "$S/log"'

echo "17. trava ocupada por outro processo vivo"
setup atrava; mkdir -p "$S/home/Library/Logs/TSA"; ln -s $$ "$S/home/Library/Logs/TSA/.atualizar-aqui.lock"
run "$CONVITE\n1\n"
check "para sem instalar" '[ $RC != 0 ] && out_has "outra atualização em andamento" && nada_instalado'
setup aporta; mkdir -p "$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta"
run "$CONVITE\n1\n"
check "porta sem pid (abandonada) recusa e diz qual pasta apagar" '[ $RC != 0 ] && out_has "lock.porta" && nada_instalado'
check "a porta abandonada não é apagada pelo script" '[ -d "$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta" ]'

echo "18. caso B2: com app e sem cadastro"
setup b2 app
find "$S" -type f -exec shasum {} + | sort >"$ANTES/b2"
run ""
check "sai 0 com a mensagem do caso B2" '[ $RC = 0 ] && out_has "Este Mac já tem o TSA"'
check "não chama a Central nem o Chaves" '! grep -qE "^(curl|security)" "$S/log"'
find "$S" -type f ! -name 'out*' ! -name 'tty*' ! -name log ! -name cfg -exec shasum {} + | sort >"$WORK/b2-depois"
check "não muda nenhum arquivo" 'diff <(grep -vE "/(out|tty)[0-9]+$|/(log|cfg)$" "$ANTES/b2") "$WORK/b2-depois" >/dev/null'

echo "19. caso B1: cadastrada, com app"
setup b1 app cadastrada atualizador
run "" --sem-agendador
check "roda o agendador com --agora, sem convite" '[ $RC = 0 ] && grep -q "^atualizar.sh --agora" "$S/log" && ! grep -q "convite/validar" "$S/cfg"'
check "aplica a marca sem-agendador" '[ -e "$(TSA_DIR)/atualizador/sem-agendador" ]'
check "mostra o resultado desta execução" 'out_has "Resultado: sem_novidade"'
setup b1velho app cadastrada atualizador
mkdir -p "$S/home/Library/Logs/TSA"; printf '{"estado":"instalada"}\n' >"$S/home/Library/Logs/TSA/atualizar-auto-ultimo.json"
touch -t 202001010000 "$S/home/Library/Logs/TSA/atualizar-auto-ultimo.json"
run "" FAKE_SEM_RESUMO=1
check "resumo velho não vira resultado" '[ $RC != 0 ] && ! out_has "Resultado: instalada" && out_has "não deixou o resultado"'
run "" FAKE_AGORA_RC=1
check "agendador com erro: para com o código" '[ $RC != 0 ] && out_has "parou com erro"'
setup b1sem app cadastrada; run ""
check "sem o script do agendador: pede para abrir o TSA" '[ $RC != 0 ] && out_has "Abra o TSA uma vez"'

echo "20. caso C: cadastrada, sem app"
setup c cadastrada perfil
run ""
check "sai 0 e reinstala" '[ $RC = 0 ] && instalado'
check "usa a credencial do Chaves pela entrada padrão" 'grep -qF "Authorization: Bearer $CRED" "$S/cfg" && grep -q "/v1/app/release?" "$S/cfg"'
check "T-INS-25: credencial nunca em argumento" 'sem_segredo_em_argumento'
check "preserva o perfil.json" 'grep -q gestao "$(TSA_DIR)/perfil.json"'
check "não pede convite" '! grep -q "convite/validar" "$S/cfg" && [ ! -e "$S/fake/chaves/tsa-convite-pendente__convite" ]'

setup cruim cadastrada perfil; printf 'curta"\nurl = "https://evil' >"$S/fake/chaves/tsa-atualizador__$UUID"
run ""
check "credencial fora do formato não entra no config do curl" '[ $RC != 0 ] && ! grep -q "evil" "$S/cfg" && nada_instalado'

echo "21. troca interrompida antes de classificar"
setup troca app cadastrada atualizador troca
run ""
check "estado.json completo (com listas): roda --retomar e segue como B1" '[ $RC = 0 ] && grep -q "^atualizar.sh --retomar" "$S/log" && grep -q "^atualizar.sh --agora" "$S/log"'
setup trocasemapp cadastrada atualizador troca
run "" FAKE_RETOMAR_FALHA=1
check "app ausente com troca pendente não vira caso C" '[ $RC != 0 ] && out_has "atualização interrompida" && nada_instalado && ! grep -q "/v1/app/release" "$S/cfg"'
setup trocafalha troca cadastrada atualizador
run "" FAKE_RETOMAR_FALHA=1
check "retomar não conclui: para sem instalar" '[ $RC != 0 ] && out_has "atualização interrompida" && nada_instalado'
setup trocailegivel troca cadastrada atualizador
run "" FAKE_RETOMAR_ILEGIVEL=1
check "estado ilegível depois do --retomar: para (CX-18-01)" '[ $RC != 0 ] && out_has "atualização interrompida" && nada_instalado'
setup trocasem troca
run ""
check "sem o script: para sem instalar" '[ $RC != 0 ] && out_has "atualização interrompida" && nada_instalado'

echo "22. atualizar.sh do painel"
S="$WORK/c-atu"; rm -rf "$S"; mkdir -p "$S/home/Library/Application Support/TSA/atualizador"
env -i HOME="$S/home" PATH=/usr/bin:/bin /bin/bash "$ATUALIZAR" >"$S/out1" 2>&1; RC=$?
check "sem o agendador: sai 1 e aponta o install.sh" '[ $RC = 1 ] && grep -q "apptsa/install.sh" "$S/out1"'
printf '#!/bin/bash\necho "modo $*" >"%s/modo"\n' "$S" >"$S/home/Library/Application Support/TSA/atualizador/atualizar.sh"
env -i HOME="$S/home" PATH=/usr/bin:/bin /bin/bash "$ATUALIZAR" >"$S/out2" 2>&1; RC=$?
check "com o agendador: roda --agora pelo bash" '[ $RC = 0 ] && [ "$(cat "$S/modo")" = "modo --agora" ]'

echo "23. versão declarada nos dois scripts"
check "TSA_SCRIPT_VERSAO no install.sh e no atualizar.sh" \
  'grep -qE "^TSA_SCRIPT_VERSAO=\"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\"$" "$SCRIPT" && grep -qE "^TSA_SCRIPT_VERSAO=\"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\"$" "$ATUALIZAR"'

echo "23b. curl de verdade com um ~/.curlrc que liga trace"
H="$WORK/curlrc-home"; mkdir -p "$H"; printf 'trace-ascii = "%s/trace.txt"\n' "$H" >"$H/.curlrc"
# Um nc local recebe o pedido, para o cabeçalho com o segredo sair de verdade.
PORTA_NC=58931
( /usr/bin/nc -l 127.0.0.1 "$PORTA_NC" >/dev/null 2>&1 & echo $! >"$H/nc.pid"; wait ) &
sleep 0.5
cfg='url = "http://127.0.0.1:'"$PORTA_NC"'/"'$'\n''header = "X-TSA-Convite: '"$CONVITE"'"'$'\n''silent'$'\n''max-time = 2'$'\n'
printf '%s' "$cfg" | env -i HOME="$H" /usr/bin/curl --config - >/dev/null 2>&1
kill "$(cat "$H/nc.pid")" 2>/dev/null
( /usr/bin/nc -l 127.0.0.1 "$PORTA_NC" >/dev/null 2>&1 & echo $! >"$H/nc.pid"; wait ) &
sleep 0.5
check "controle: sem -q o trace grava o segredo" '[ -f "$H/trace.txt" ] && grep -qF "$CONVITE" "$H/trace.txt"'
rm -f "$H/trace.txt"
printf '%s' "$cfg" | env -i HOME="$H" /usr/bin/curl -q --config - >/dev/null 2>&1
kill "$(cat "$H/nc.pid")" 2>/dev/null
check "com -q primeiro, nada de trace" '[ ! -e "$H/trace.txt" ]'

echo "24. security -i de verdade num chaveiro temporário, com captura do ps (§8.6, T-INS-25)"
# Chaveiro só do teste: o login do Mac não é tocado. O ps é lido a cada 20 ms durante a
# execução inteira, procurando o convite em argumento de qualquer processo.
KC="$WORK/teste.keychain-db"
/usr/bin/security create-keychain -p senha-teste "$KC" >/dev/null 2>&1 &&
  /usr/bin/security unlock-keychain -p senha-teste "$KC" >/dev/null 2>&1
setup real
( while [ ! -e "$S/fim" ]; do ps -axww -o args= | grep -F "$CONVITE" | grep -v grep >>"$S/ps.txt"; sleep 0.02; done ) &
VIGIA=$!
run "$CONVITE\n1\n" TSA_SECURITY=/usr/bin/security TSA_KEYCHAIN="$KC"
touch "$S/fim"; wait "$VIGIA" 2>/dev/null
check "sai 0" '[ $RC = 0 ]'
check "o convite ficou no item tsa-convite-pendente do chaveiro" \
  '[ "$(/usr/bin/security find-generic-password -s tsa-convite-pendente -a convite -w "$KC" 2>/dev/null)" = "$CONVITE" ]'
check "nenhum processo teve o convite em argumento" '[ ! -s "$S/ps.txt" ]'
/usr/bin/security delete-keychain "$KC" >/dev/null 2>&1

echo
echo "$PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
