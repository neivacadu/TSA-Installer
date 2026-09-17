#!/bin/bash
# Testa a preparacao do simulador em docs/install.sh sem instalar nada de verdade.
# brew, python3, node, psql, pg_isready, xcode-select, ffmpeg, agy e curl sao falsos e
# registram cada
# chamada num log. O PATH do teste so tem os falsos e utilitarios basicos; HOME e
# um diretorio temporario. Os cenarios com risco de repeticao rodam duas vezes.
#   bash scripts/test-install-prereqs.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docs/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsa-prereqs-test.XXXXXX")"
NC_PID=""
cleanup(){ [ -n "$NC_PID" ] && kill "$NC_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# utilitarios reais que o instalador usa no modo so-preparacao
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN"
for t in uname dirname basename readlink grep sed sleep cat mkdir cp touch chmod mktemp rm id ln head; do
  ln -s "$(command -v "$t")" "$SYSBIN/$t"
done

# porta livre para os cenarios normais; a porta real 5432 desta maquina fica fora do teste
free_port(){
  local p
  for p in 55432 55433 55434 55435 55436 55437; do
    /usr/bin/nc -z 127.0.0.1 "$p" 2>/dev/null || { echo "$p"; return; }
  done
}
PORT_FREE="$(free_port)"

# modelos dos binarios falsos
TPL="$WORK/tpl"
mkdir -p "$TPL"
fake(){ # nome, corpo
  printf '#!/bin/bash\necho "%s $*" >>"$FAKE_LOG"\n%s\n' "$1" "$2" >"$TPL/$1"
  chmod +x "$TPL/$1"
}
fake python3 'case "$*" in *python_version*) echo 3.14.0;; esac; exit 0'
fake syspython3 'exit 1'
fake xcode-select 'exit 2'
fake node 'echo v22.0.0'
fake ffmpeg 'echo ffmpeg version 7.1'
fake agy 'case "$*" in *--version*) echo 1.2.5;; esac; exit 0'
# curl falso: -I responde conforme FAKE_AGY_URL_OK; -o grava um instalador falso do agy
fake curl '
case "$*" in
  *-fsSI*) [ "${FAKE_AGY_URL_OK:-1}" = 1 ] ;;
  *)
    prev=""; out=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] || exit 0
    { echo "#!/bin/bash"; echo "mkdir -p \"$HOME/.local/bin\""; echo "cp \"$FAKE_TPL/agy\" \"$HOME/.local/bin/agy\""; } >"$out"
    ;;
esac'
fake psql '[ -e "$FAKE_STATE/pg_running" ] || exit 2; case "$*" in *server_version_num*) echo "${FAKE_PG_VERSION:-160004}";; esac; exit 0'
fake pg_isready '[ -e "$FAKE_STATE/pg_running" ]'
fake createdb '[ -e "$FAKE_STATE/pg_running" ]'
fake brew '
P="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
  --prefix) echo "$P" ;;
  shellenv) echo "export PATH=\"$P/bin:\$PATH\"" ;;
  install)
    case "$2" in
      python@3.14) cp "$FAKE_TPL/python3" "$P/bin/python3"; cp "$FAKE_TPL/python3" "$P/bin/python3.14" ;;
      node) cp "$FAKE_TPL/node" "$P/bin/node" ;;
      ffmpeg) cp "$FAKE_TPL/ffmpeg" "$P/bin/ffmpeg" ;;
      postgresql@16) mkdir -p "$P/opt/postgresql@16/bin"
        cp "$FAKE_TPL/psql" "$FAKE_TPL/pg_isready" "$FAKE_TPL/createdb" "$P/opt/postgresql@16/bin/" ;;
    esac ;;
  link) [ -n "${FAKE_LINKFAIL:-}" ] && exit 1; cp "$P/opt/$3/bin/"* "$P/bin/" ;;
  services) [ "$2" = start ] && touch "$FAKE_STATE/pg_running" ;;
esac
exit 0'

PASS=0
FAIL=0

# setup: cenario novo. Ferramentas vao para userbin; brew vai para prefix/bin.
# Opcoes: pg_on liga o servidor; psql_cellar e keg16/keg14 simulam o brew real.
setup(){
  S="$WORK/$1"; shift
  mkdir -p "$S/userbin" "$S/prefix/bin" "$S/prefix/opt" "$S/state" "$S/home"
  : >"$S/log"
  BREW_ON_PATH=1
  RUNS=0
  local b
  for b in "$@"; do
    case "$b" in
      pg_on) touch "$S/state/pg_running" ;;
      brew) cp "$TPL/brew" "$S/prefix/bin/brew" ;;
      agy_login) mkdir -p "$S/home/.gemini"; echo '{"token":"falso"}' >"$S/home/.gemini/oauth_creds.json" ;;
      psql_cellar)
        mkdir -p "$S/prefix/Cellar/postgresql@16/16.4/bin"
        cp "$TPL/psql" "$TPL/pg_isready" "$S/prefix/Cellar/postgresql@16/16.4/bin/"
        ln -s ../Cellar/postgresql@16/16.4/bin/psql "$S/prefix/bin/psql"
        ln -s ../Cellar/postgresql@16/16.4/bin/pg_isready "$S/prefix/bin/pg_isready" ;;
      keg16|keg14)
        local k="$S/prefix/opt/postgresql@${b#keg}/bin"
        mkdir -p "$k"; cp "$TPL/psql" "$TPL/pg_isready" "$k/" ;;
      *) cp "$TPL/$b" "$S/userbin/$b" ;;
    esac
  done
}

# run: roda o instalador no cenario atual, com vigia contra travamento.
# Argumentos extras viram variaveis de ambiente. Saida em out1, out2...
RUNS=0
run(){
  RUNS=$((RUNS + 1))
  OUT="$S/out$RUNS"
  local path="$S/userbin:$SYSBIN" cand=""
  if [ "$BREW_ON_PATH" = 1 ]; then path="$S/userbin:$S/prefix/bin:$SYSBIN"
  else cand="$S/prefix/bin/brew"; fi
  env -i HOME="$S/home" PATH="$path" TMPDIR="$WORK" \
    FAKE_LOG="$S/log" FAKE_STATE="$S/state" FAKE_TPL="$TPL" \
    TSA_ONLY_PREREQS=1 TSA_TTY=/nonexistent/tty TSA_BREW_CANDIDATES="$cand" TSA_PG_WAIT=3 \
    TSA_PG_PORT="$PORT_FREE" TSA_POSTGRES_APP="$S/Postgres.app" TSA_SYS_PYTHON=/nonexistent/python3 \
    "$@" /bin/bash "$SCRIPT" >"$OUT" 2>&1 </dev/null &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 200 ]; then kill "$pid"; echo "TRAVOU" >>"$OUT"; break; fi
    sleep 0.1
  done
  wait "$pid"
  RC=$?
}
# run2: duas execucoes seguidas; RC1/RC2 e log separado da primeira
run2(){
  run "$@"; RC1=$RC; cp "$S/log" "$S/log1"; : >"$S/log"
  run "$@"; RC2=$RC
}

check(){ # descricao, condicao
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok     $1"
  else FAIL=$((FAIL + 1)); echo "  FALHOU $1"; sed 's/^/       | /' "$S"/out* "$S"/log*; fi
}
# todas as chamadas ao brew, e so as que mudam a maquina
brew_calls(){ grep '^brew ' "${1:-$S/log}" | tr '\n' ';'; }
brew_changes(){ grep -E '^brew (install|link|unlink|services|upgrade|reinstall)' "${1:-$S/log}" | tr '\n' ';'; }
zcount(){ grep -c "$1" "$S/home/.zprofile" 2>/dev/null || true; }
out_has(){ grep -q "$1" "$OUT"; }

echo "1. tudo presente"
setup all brew python3 node psql pg_isready pg_on ffmpeg agy agy_login
run
check "sai 0" '[ $RC = 0 ]'
check "nenhuma chamada ao brew" '[ -z "$(brew_calls)" ]'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'
check ".zprofile intocado" '[ ! -e "$S/home/.zprofile" ]'

echo "2. sem Python"
setup nopy brew node psql pg_isready pg_on ffmpeg agy agy_login
run
check "sai 0" '[ $RC = 0 ]'
check "so instala o Python" '[ "$(brew_changes)" = "brew install python@3.14;" ]'
check "resumo mostra Python instalado" 'out_has "Python 3.14.0: instalado"'

echo "3. sem Postgres"
setup nopg brew python3 node ffmpeg agy agy_login
run
check "sai 0" '[ $RC = 0 ]'
check "instala, linka e liga o postgresql@16" \
  '[ "$(brew_changes)" = "brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;" ]'
check "confere com select 1" 'grep -q "^psql -w -d postgres -c select 1" "$S/log"'
check "confere a versao do servidor" 'grep -q "server_version_num" "$S/log"'
check "resumo mostra PostgreSQL ligado" 'out_has "PostgreSQL 16: instalado e ligado"'

echo "4. psql presente e servidor parado"
setup pgoff brew python3 node psql_cellar ffmpeg agy agy_login
run
check "sai 1" '[ $RC = 1 ]'
check "nao chama o brew" '[ -z "$(brew_calls)" ]'
check "informa servidor parado" 'out_has "servidor nao responde"'
check "da o comando de ligar" 'out_has "Para resolver: brew services start postgresql@16"'

echo "5. sem brew e sem tty"
setup nobrew node psql pg_isready pg_on ffmpeg agy agy_login
run
check "termina sem travar" '! out_has TRAVOU'
check "sai 1" '[ $RC = 1 ]'
check "informa falta de terminal" 'out_has "sem terminal para pedir a senha"'
check "da o comando para o Python" 'out_has "brew install python@3.14"'

echo "6. TSA_SKIP_PREREQS=1"
setup skip
run TSA_SKIP_PREREQS=1
check "sai 0" '[ $RC = 0 ]'
check "nenhuma chamada registrada" '[ ! -s "$S/log" ]'
check "avisa que pulou" 'out_has "pulada"'

echo "7. brew fora do PATH, duas execucoes"
setup offpath brew node psql pg_isready pg_on ffmpeg agy agy_login
BREW_ON_PATH=0
run2
check "1a: sai 0 e instala so o Python" '[ $RC1 = 0 ] && [ "$(brew_changes "$S/log1")" = "brew install python@3.14;" ]'
check "2a: sai 0 e nao instala nada" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'
check "2a: acha o Python do brew" 'out_has "Python 3.14.0: ja estava pronto"'
check ".zprofile com uma linha do shellenv" '[ "$(zcount "brew shellenv")" = 1 ]'

echo "8. postgresql@16 ja instalado sem link, duas execucoes"
setup keg brew python3 node keg16 pg_on ffmpeg agy agy_login
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao instala nem linka" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "resumo diz ligado" 'out_has "PostgreSQL: ja estava ligado"'
check ".zprofile com uma linha do keg" '[ "$(zcount "opt/postgresql@16/bin")" = 1 ]'

echo "9. conflito no brew link, duas execucoes"
setup linkfail brew python3 node ffmpeg agy agy_login
run2 FAKE_LINKFAIL=1
check "1a: instala, tenta o link e liga" \
  '[ "$(brew_changes "$S/log1")" = "brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;" ]'
check "1a: avisa o conflito e termina ligado" 'grep -q "deu conflito" "$S/out1" && grep -q "instalado e ligado" "$S/out1"'
check "2a: nao instala nem linka" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'
check ".zprofile com uma linha do keg" '[ "$(zcount "opt/postgresql@16/bin")" = 1 ]'

echo "10. /usr/bin/python3 sem Command Line Tools, duas execucoes"
setup noclt brew node psql pg_isready pg_on xcode-select ffmpeg agy agy_login
cp "$TPL/syspython3" "$S/userbin/python3"
run2 TSA_SYS_PYTHON="$S/userbin/python3"
check "1a: nao executa o python do sistema" '! grep -q "^syspython3" "$S/log1"'
check "1a: consulta o xcode-select" 'grep -q "^xcode-select" "$S/log1"'
check "1a: instala o Python" '[ "$(brew_changes "$S/log1")" = "brew install python@3.14;" ]'
check "2a: nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "11. porta 5432 ocupada sem psql, duas execucoes"
setup port brew python3 node ffmpeg agy agy_login
PORT_BUSY="$(free_port)"
/usr/bin/nc -lk "$PORT_BUSY" >/dev/null 2>&1 </dev/null &
NC_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/nc -z 127.0.0.1 "$PORT_BUSY" 2>/dev/null && break; sleep 0.2; done
run2 TSA_PG_PORT="$PORT_BUSY"
kill "$NC_PID" 2>/dev/null; wait "$NC_PID" 2>/dev/null; NC_PID=""
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "informa a porta em uso" "out_has \"porta $PORT_BUSY ja esta em uso\""
check "nunca diz instalado e ligado" '! grep -q "instalado e ligado" "$S"/out*'

echo "12. Postgres.app fora do PATH, duas execucoes"
setup pgapp brew python3 node ffmpeg agy agy_login
mkdir -p "$S/Postgres.app/Contents/Versions/latest/bin"
cp "$TPL/psql" "$S/Postgres.app/Contents/Versions/latest/bin/"
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "informa o app e o caminho real" 'out_has "Postgres.app/Contents/Versions/latest/bin"'
check ".zprofile intocado" '[ ! -e "$S/home/.zprofile" ]'

echo "13. outra versao do brew sem link (postgresql@14), duas execucoes"
setup keg14 brew python3 node keg14 ffmpeg agy agy_login
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "informa o caminho do keg" 'out_has "opt/postgresql@14/bin"'
check "da o comando de ligar" 'out_has "brew services start postgresql@14"'

echo "14. servidor que responde nao e o 16"
setup otherver brew python3 node ffmpeg agy agy_login
run FAKE_PG_VERSION=150008
check "sai 1" '[ $RC = 1 ]'
check "nao diz instalado e ligado" '! out_has "instalado e ligado"'
check "informa outro servidor" 'out_has "quem respondeu foi outro servidor (versao 150008)"'

echo "15. faltando tudo, segunda execucao nao reinstala"
setup again brew curl agy_login
run2
check "1a: instala Python, Node, PostgreSQL e ffmpeg" \
  '[ "$(brew_changes "$S/log1")" = "brew install python@3.14;brew install node;brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;brew install ffmpeg;" ]'
check "1a: instala o agy pelo instalador oficial" '[ -x "$S/home/.local/bin/agy" ]'
check "2a: sai 0 sem chamar o brew nem o curl" '[ $RC2 = 0 ] && [ -z "$(brew_calls)" ] && ! grep -q "^curl" "$S/log"'

echo "16. ffmpeg e agy presentes, com login, duas execucoes"
setup midiaok brew python3 node psql pg_isready pg_on ffmpeg agy agy_login
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao chama brew nem curl" '[ -z "$(brew_calls "$S/log1")$(brew_calls)" ] && ! grep -q "^curl" "$S/log1" "$S/log"'
check "resumo: ffmpeg pronto" 'out_has "ffmpeg: ja estava pronto"'
check "resumo: agy com login" 'out_has "Antigravity agy 1.2.5: ja estava pronto, com login feito"'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'

echo "17. agy presente e sem login, duas execucoes"
setup semlogin brew python3 node psql pg_isready pg_on ffmpeg agy
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_calls "$S/log1")$(brew_calls)" ] && ! grep -q "^curl" "$S/log"'
check "resumo: sem login" 'out_has "Antigravity agy 1.2.5: ja estava pronto, mas sem login."'
check "resumo: instrucao de login" 'out_has "escolha Google OAuth"'
check "resumo: aviso da janela" 'out_has "campo do codigo fica escondido"'

echo "18. sem ffmpeg, duas execucoes"
setup noff brew python3 node psql pg_isready pg_on agy agy_login
run2
check "1a: instala so o ffmpeg" '[ "$(brew_changes "$S/log1")" = "brew install ffmpeg;" ]'
check "1a: resumo diz instalado" 'grep -q "ffmpeg: instalado" "$S/out1"'
check "2a: nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "19. sem agy, duas execucoes"
setup noagy brew python3 node psql pg_isready pg_on ffmpeg curl agy_login
run2
check "1a: confere o endereco antes de baixar" 'grep -q "^curl -fsSI" "$S/log1"'
check "1a: baixa e roda o instalador oficial" 'grep -q "^curl -fsSL" "$S/log1" && [ -x "$S/home/.local/bin/agy" ]'
check "1a: resumo diz instalado com login" 'grep -q "Antigravity agy 1.2.5: instalado, com login feito" "$S/out1"'
check "1a: nao usa o brew para o agy" '[ -z "$(brew_changes "$S/log1")" ]'
check "2a: acha em ~/.local/bin sem baixar" '[ $RC2 = 0 ] && ! grep -q "^curl" "$S/log"'
check ".zprofile com uma linha do ~/.local/bin" '[ "$(zcount ".local/bin")" = 1 ]'

echo "20. sem agy e endereco fora do ar, duas execucoes"
setup agyoff brew python3 node psql pg_isready pg_on ffmpeg curl
run2 FAKE_AGY_URL_OK=0
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "confere o endereco e nao baixa" 'grep -q "^curl -fsSI" "$S/log1" && ! grep -q "^curl -fsSL" "$S/log1"'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")" ] && [ ! -e "$S/home/.local/bin/agy" ]'
check "resumo informa o endereco" 'out_has "nao respondeu 200"'

echo
echo "resultado: $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
