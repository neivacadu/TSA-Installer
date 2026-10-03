#!/bin/bash
# Testa a troca segura do app em docs/install.sh (ACH-INS-20; INSTALAR-F2-CONTRATO v2.0,
# secao 4.5, regra 6): copia que falha, mv que falha e interrupcao depois de cada passo (a) a
# (d), sempre terminando, na mesma execucao ou na seguinte, com um TSA.app que passa no
# codesign --verify. Sem rede e sem /Applications real: curl, hdiutil, ditto, xattr, mv, pgrep
# e open sao falsos; o destino e uma pasta temporaria. O codesign e falso nas secoes 1 a 12 e
# o de verdade na secao 13, com um bundle de verdade assinado ad-hoc.
#   bash scripts/test-install-troca.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docs/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsa-troca-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN"
for t in uname dirname basename readlink grep sed sleep cat mkdir cp touch chmod mktemp rm id ln head awk find shasum env tr; do
  ln -s "$(command -v "$t")" "$SYSBIN/$t"
done
DMG_SHA="$(head -c 4096 /dev/zero | shasum -a 256 | awk '{print $1}')"

FAKE="$WORK/fakebin"
mkdir -p "$FAKE"
fake(){ printf '#!/bin/bash\necho "%s $*" >>"$FAKE_LOG"\n%s\n' "$1" "$2" >"$FAKE/$1"; chmod +x "$FAKE/$1"; }
fake curl '
o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done
[ -n "${FAKE_CURL_FALHA:-}" ] && exit 22
case "$o" in
  *checksums-sha256.txt) printf "%s  tsa-macos-arm64.dmg\n" "$FAKE_DMG_SHA" >"$o" ;;
  *) head -c 4096 /dev/zero >"$o" ;;
esac'
# O pacote: TSA.app com o binario e o tsa-version.json do build novo. Com FAKE_BUNDLE_REAL, copia
# um bundle de verdade, assinado ad-hoc no comeco do teste.
fake hdiutil '
case "$1" in
  attach)
    rm -rf "$FAKE_VOLUME/TSA.app"
    A="$FAKE_VOLUME/TSA.app/Contents"
    if [ -n "${FAKE_BUNDLE_REAL:-}" ]; then mkdir -p "$FAKE_VOLUME"; cp -R "$FAKE_BUNDLE_REAL" "$FAKE_VOLUME/TSA.app"
    else
      mkdir -p "$A/MacOS" "$A/Resources/tsa"
      echo novo >"$A/MacOS/TSA"
      [ -z "${FAKE_SEM_VERSAO:-}" ] && printf "{\"build_id\":\"%s\"}\n" "$FAKE_BUILD_NOVO" >"$A/Resources/tsa/tsa-version.json"
    fi
    printf "/dev/disk9\tGUID_partition_scheme\t\n/dev/disk9s1\tApple_HFS\t%s\n" "$FAKE_VOLUME" ;;
esac
exit 0'
# ditto que falha deixa uma copia pela metade (sem o binario)
fake ditto '
if [ -n "${FAKE_DITTO_FALHA:-}" ]; then mkdir -p "$2/Contents"; exit 1; fi
cp -R "$1" "$2"
[ -n "${FAKE_DITTO_BUILD_ERRADO:-}" ] && printf "{\"build_id\":\"abc1234.20200101T000000Z\"}\n" >"$2/Contents/Resources/tsa/tsa-version.json"
exit 0'
# app valido = tem o binario e nao tem a marca INVALIDO; FAKE_CODESIGN_RUIM reprova a copia nova
fake codesign '
[ -n "${FAKE_CODESIGN_REAL:-}" ] && exec /usr/bin/codesign "$@"
case "$1" in
  --verify)
    a="${@: -1}"
    [ -n "${FAKE_CODESIGN_RUIM:-}" ] && case "$a" in *.TSA-novo.app) exit 1 ;; esac
    [ -f "$a/Contents/MacOS/TSA" ] && [ ! -e "$a/INVALIDO" ] ;;
  *) exit 0 ;;
esac'
fake xattr 'exit 0'
fake pgrep 'exit 1'
fake osascript 'exit 0'
fake defaults 'echo com.trafegosa.orca-tsa'
fake open 'exit 0'
# mv que falha no passo c (anterior para o lado) ou d (novo para o lugar)
fake mv '
case "${FAKE_MV_FALHA:-}" in
  c) case "$1:$2" in */TSA.app:*.TSA-anterior.app) exit 1 ;; esac ;;
  d) case "$1:$2" in *.TSA-novo.app:*/TSA.app) exit 1 ;; esac ;;
esac
exec /bin/mv "$@"'

NOVO_ID="49d050c9f.20261002T135453Z"
VELHO_ID="0496331a8.20260926T124615Z"

setup(){ # nome, [velho|velho_invalido|nada]
  S="$WORK/$1"; rm -rf "$S"; mkdir -p "$S/home" "$S/Applications"; : >"$S/log"; RUNS=0
  case "${2:-velho}" in
    velho|velho_invalido)
      local a="$S/Applications/TSA.app/Contents"
      mkdir -p "$a/MacOS" "$a/Resources/tsa"; echo velho >"$a/MacOS/TSA"
      printf '{"build_id":"%s"}\n' "$VELHO_ID" >"$a/Resources/tsa/tsa-version.json"
      [ "${2:-velho}" = velho_invalido ] && touch "$S/Applications/TSA.app/INVALIDO" ;;
  esac
}
run(){
  RUNS=$((RUNS + 1)); OUT="$S/out$RUNS"
  ( env -i HOME="$S/home" PATH="$FAKE:$SYSBIN" TMPDIR="$WORK" FAKE_LOG="$S/log" \
    FAKE_VOLUME="$S/volume" FAKE_BUILD_NOVO="$NOVO_ID" FAKE_DMG_SHA="$DMG_SHA" \
    TSA_SKIP_PREREQS=1 TSA_APP_DEST="$S/Applications" TSA_TTY=/nonexistent/tty \
    TSA_PGREP="$FAKE/pgrep" TSA_OSASCRIPT="$FAKE/osascript" TSA_DEFAULTS="$FAKE/defaults" \
    TSA_OPEN="$FAKE/open" TSA_PLUTIL=/usr/bin/plutil TSA_TRAVA_DIR="$S/home/Library/Logs/TSA" \
    "$@" /bin/bash "$SCRIPT" >"$OUT" 2>&1 </dev/null ) 2>/dev/null
  RC=$?
}
check(){
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok     $1"
  else FAIL=$((FAIL + 1)); echo "  FALHOU $1"; sed 's/^/       | /' "$S"/out* ; ls -la "$S/Applications" | sed 's/^/       | /'; fi
}
APPS(){ printf '%s' "$S/Applications"; }
app_valido(){ [ -f "$(APPS)/TSA.app/Contents/MacOS/TSA" ] && [ ! -e "$(APPS)/TSA.app/INVALIDO" ]; }
build_atual(){ /usr/bin/plutil -extract build_id raw -o - "$(APPS)/TSA.app/Contents/Resources/tsa/tsa-version.json" 2>/dev/null; }
sem_sobras(){ [ ! -e "$(APPS)/.TSA-novo.app" ] && [ ! -e "$(APPS)/.TSA-anterior.app" ] && [ ! -e "$(APPS)/.TSA-falhou.app" ]; }
velho(){ app_valido && [ "$(build_atual)" = "$VELHO_ID" ]; }
novo(){ app_valido && [ "$(build_atual)" = "$NOVO_ID" ]; }

echo "1. instalacao nova (sem app)"
setup nova nada; run
check "sai 0 com o app novo" '[ $RC = 0 ] && novo'
check "sem sobras" 'sem_sobras'

echo "2. atualizacao normal"
setup normal; run
check "sai 0 com o app novo" '[ $RC = 0 ] && novo'
check "sem sobras" 'sem_sobras'

echo "3. ditto falha no passo a"
setup ditto; run FAKE_DITTO_FALHA=1
check "para e o app velho fica" '[ $RC != 0 ] && velho && sem_sobras'

echo "4. copia nao passa no codesign (passo b)"
setup codesign; run FAKE_CODESIGN_RUIM=1
check "para e o app velho fica" '[ $RC != 0 ] && velho && sem_sobras'

echo "5. copia com outro build_id (passo b)"
setup build; run FAKE_DITTO_BUILD_ERRADO=1
check "para e o app velho fica" '[ $RC != 0 ] && velho && sem_sobras'

echo "6. mv falha no passo c"
setup mvc; run FAKE_MV_FALHA=c
check "para e o app velho fica" '[ $RC != 0 ] && velho && sem_sobras'

echo "7. mv falha no passo d"
setup mvd; run FAKE_MV_FALHA=d
check "para e o app velho volta" '[ $RC != 0 ] && velho && sem_sobras'

# Queda de energia (KILL): nada roda no fim. A execucao seguinte devolve o anterior antes de
# tudo, mesmo se o download dela falhar, e a terceira termina a troca.
for p in a b c d; do
  echo "8$p. KILL depois do passo $p"
  setup kill$p; run TSA_TESTE_PARAR_TROCA=$p
  check "a 1a execucao morreu" '[ $RC != 0 ]'
  run FAKE_CURL_FALHA=1
  if [ "$p" = d ]; then
    check "2a (download falha): fica o app novo, que confere, sem sobras" 'novo && sem_sobras'
  else
    check "2a (download falha): o app velho esta no lugar, sem sobras" 'velho && sem_sobras'
  fi
  run
  check "3a: termina com o app novo, sem sobras" '[ $RC = 0 ] && novo && sem_sobras'
done

# Ctrl+C ou TERM: o cleanup da propria execucao devolve o anterior.
for p in a b c d; do
  echo "9$p. TERM depois do passo $p"
  setup term$p; run TSA_TESTE_PARAR_TROCA=$p TSA_TESTE_SINAL=TERM
  if [ "$p" = d ]; then
    check "na mesma execucao: fica o app novo, sem sobras" '[ $RC != 0 ] && novo && sem_sobras'
  else
    check "na mesma execucao: o app velho volta, sem sobras" '[ $RC != 0 ] && velho && sem_sobras'
  fi
done

echo "10. app novo invalido e anterior presentes (troca interrompida depois do d)"
setup ambos velho
/bin/mv "$S/Applications/TSA.app" "$S/Applications/.TSA-anterior.app"
mkdir -p "$S/Applications/TSA.app/Contents/MacOS"; echo ruim >"$S/Applications/TSA.app/Contents/MacOS/TSA"
touch "$S/Applications/TSA.app/INVALIDO"
run FAKE_CURL_FALHA=1
check "o anterior volta ao lugar, sem sobras" 'velho && sem_sobras'

echo "11. trava ocupada por outro processo vivo (atualiza aqui ou agendador)"
setup trava; mkdir -p "$S/home/Library/Logs/TSA"; ln -s $$ "$S/home/Library/Logs/TSA/.atualizar-aqui.lock"
/bin/mv "$S/Applications/TSA.app" "$S/Applications/.TSA-anterior.app"
run
check "recusa sem mexer em nada, nem na recuperacao" \
  '[ $RC != 0 ] && grep -q "outra atualizacao" "$OUT" && [ -d "$(APPS)/.TSA-anterior.app" ] && [ ! -e "$(APPS)/TSA.app" ]'
check "nao baixa nada" '! grep -q "^curl" "$S/log"'
rm -f "$S/home/Library/Logs/TSA/.atualizar-aqui.lock"
mkdir -p "$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta"; echo 999999 >"$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta/pid"
run
check "porta abandonada (pid morto) recusa sem mexer e diz qual pasta apagar (CX-18-13)" \
  '[ $RC != 0 ] && grep -q "lock.porta" "$OUT" && [ -d "$(APPS)/.TSA-anterior.app" ] && [ ! -e "$(APPS)/TSA.app" ]'
rm -rf "$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta"
ln -s 999999 "$S/home/Library/Logs/TSA/.atualizar-aqui.lock"
run
check "trava de pid morto (sem porta) e retomada; recupera e instala" '[ $RC = 0 ] && novo && sem_sobras'
check "trava e porta soltas no fim" '[ ! -e "$S/home/Library/Logs/TSA/.atualizar-aqui.lock" ] && [ ! -e "$S/home/Library/Logs/TSA/.atualizar-aqui.lock.porta" ]'

echo "12. pacote sem tsa-version.json (build_id ilegivel nos dois lados)"
setup semversao; run FAKE_SEM_VERSAO=1
check "para e o app velho fica" '[ $RC != 0 ] && velho && sem_sobras'
setup agfalhou; mkdir -p "$S/Applications/.TSA-falhou.app/Contents"; run
check "o .TSA-falhou.app do agendador fica para o suporte" '[ $RC = 0 ] && novo && [ -d "$(APPS)/.TSA-falhou.app" ]'

echo "13. bundle de verdade e codesign de verdade"
# Executavel = /usr/bin/true; id de teste, nunca o do TSA. "Abre" = o executavel do app instalado
# roda e sai 0 (o open do LaunchServices fica fora: registraria o bundle de teste no Mac).
REAL="$WORK/real/TSA.app"; mkdir -p "$REAL/Contents/MacOS" "$REAL/Contents/Resources/tsa"
cp /usr/bin/true "$REAL/Contents/MacOS/TSA"
/usr/bin/plutil -create xml1 "$REAL/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.trafegosa.teste-troca "$REAL/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string TSA "$REAL/Contents/Info.plist"
printf '{"build_id":"%s"}\n' "$NOVO_ID" >"$REAL/Contents/Resources/tsa/tsa-version.json"
/usr/bin/codesign --force --sign - "$REAL" >/dev/null 2>&1
check "o bundle de teste passa no codesign de verdade" '/usr/bin/codesign --verify --deep --strict "$REAL"'
real_ok(){ /usr/bin/codesign --verify --deep --strict "$(APPS)/TSA.app" 2>/dev/null && "$(APPS)/TSA.app/Contents/MacOS/TSA" && [ "$(build_atual)" = "$NOVO_ID" ]; }
real_velho(){ /usr/bin/codesign --verify --deep --strict "$(APPS)/TSA.app" 2>/dev/null && [ "$(build_atual)" = "$VELHO_ID" ]; }
setup_real(){ setup "$1" nada; local v="$(APPS)/TSA.app"; cp -R "$REAL" "$v"
  printf '{"build_id":"%s"}\n' "$VELHO_ID" >"$v/Contents/Resources/tsa/tsa-version.json"
  /usr/bin/codesign --force --sign - "$v" >/dev/null 2>&1; }
R="FAKE_CODESIGN_REAL=1 FAKE_BUNDLE_REAL=$REAL"
setup_real real1; run $R
check "atualizacao: o app novo passa no codesign e abre" '[ $RC = 0 ] && real_ok && sem_sobras'
setup_real real2; run $R FAKE_DITTO_FALHA=1
check "copia pela metade reprova no codesign real; o velho fica" '[ $RC != 0 ] && real_velho && sem_sobras'
setup_real real3; run $R TSA_TESTE_PARAR_TROCA=c; run $R FAKE_CURL_FALHA=1
check "KILL depois do c: a seguinte devolve o velho, que passa no codesign" 'real_velho && sem_sobras'
run $R
check "e a terceira instala o novo, que passa e abre" '[ $RC = 0 ] && real_ok && sem_sobras'
setup_real real4; run $R TSA_TESTE_PARAR_TROCA=d TSA_TESTE_SINAL=TERM
check "TERM depois do d: fica o novo, que passa e abre" 'real_ok && sem_sobras'

echo
echo "$PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
