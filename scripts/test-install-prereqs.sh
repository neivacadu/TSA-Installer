#!/bin/bash
# Testa a preparacao do simulador em docs/install.sh sem instalar nada de verdade.
# brew, python3, node, psql e pg_isready sao falsos e registram cada chamada num log.
# O PATH do teste so tem os falsos e utilitarios basicos; HOME e um diretorio temporario.
#   bash scripts/test-install-prereqs.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docs/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsa-prereqs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# utilitarios reais que o instalador usa no modo so-preparacao
SYSBIN="$WORK/sysbin"
mkdir -p "$SYSBIN"
for t in uname dirname readlink grep sed sleep cat mkdir cp touch chmod mktemp rm id ln; do
  ln -s "$(command -v "$t")" "$SYSBIN/$t"
done

# modelos dos binarios falsos
TPL="$WORK/tpl"
mkdir -p "$TPL"
fake(){ # nome, corpo
  printf '#!/bin/bash\necho "%s $*" >>"$FAKE_LOG"\n%s\n' "$1" "$2" >"$TPL/$1"
  chmod +x "$TPL/$1"
}
fake python3 'case "$*" in *python_version*) echo 3.14.0;; esac; exit 0'
fake node 'echo v22.0.0'
fake psql '[ -e "$FAKE_STATE/pg_running" ]'
fake pg_isready '[ -e "$FAKE_STATE/pg_running" ]'
fake createdb '[ -e "$FAKE_STATE/pg_running" ]'
fake brew '
P="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
  install)
    case "$2" in
      python@3.14) cp "$FAKE_TPL/python3" "$P/bin/python3" ;;
      node) cp "$FAKE_TPL/node" "$P/bin/node" ;;
      postgresql@16) mkdir -p "$P/opt/postgresql@16/bin"
        cp "$FAKE_TPL/psql" "$FAKE_TPL/pg_isready" "$FAKE_TPL/createdb" "$P/opt/postgresql@16/bin/" ;;
    esac ;;
  link) cp "$P/opt/$3/bin/"* "$P/bin/" ;;
  services) [ "$2" = start ] && touch "$FAKE_STATE/pg_running" ;;
esac
exit 0'

PASS=0
FAIL=0

# setup: cria um cenario novo. Argumentos: binarios presentes; "pg_on" liga o servidor.
setup(){
  S="$WORK/$1"; shift
  mkdir -p "$S/prefix/bin" "$S/prefix/opt" "$S/state" "$S/home"
  : >"$S/log"
  local b
  for b in "$@"; do
    case "$b" in
      pg_on) touch "$S/state/pg_running" ;;
      psql_cellar) # psql como link do Cellar, igual ao brew real
        mkdir -p "$S/prefix/Cellar/postgresql@16/16.4/bin"
        cp "$TPL/psql" "$TPL/pg_isready" "$S/prefix/Cellar/postgresql@16/16.4/bin/"
        ln -s ../Cellar/postgresql@16/16.4/bin/psql "$S/prefix/bin/psql"
        ln -s ../Cellar/postgresql@16/16.4/bin/pg_isready "$S/prefix/bin/pg_isready" ;;
      *) cp "$TPL/$b" "$S/prefix/bin/$b" ;;
    esac
  done
}

# run: roda o instalador no cenario atual, com vigia contra travamento
run(){
  env -i HOME="$S/home" PATH="$S/prefix/bin:$SYSBIN" TMPDIR="$WORK" \
    FAKE_LOG="$S/log" FAKE_STATE="$S/state" FAKE_TPL="$TPL" \
    TSA_ONLY_PREREQS=1 TSA_TTY=/nonexistent/tty TSA_BREW_CANDIDATES="" TSA_PG_WAIT=3 \
    "$@" /bin/bash "$SCRIPT" >"$S/out" 2>&1 </dev/null &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 200 ]; then kill "$pid"; echo "TRAVOU" >>"$S/out"; break; fi
    sleep 0.1
  done
  wait "$pid"
  RC=$?
}

check(){ # descricao, condicao
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FALHOU $1"; sed 's/^/       | /' "$S/out" "$S/log"; fi
}
brew_calls(){ grep '^brew ' "$S/log" | tr '\n' ';'; }

echo "1. tudo presente"
setup all brew python3 node psql pg_isready pg_on
run
check "sai 0" '[ $RC = 0 ]'
check "nenhuma chamada ao brew" '[ -z "$(brew_calls)" ]'
check "resumo diz tudo pronto" 'grep -q "Tudo pronto" "$S/out"'
check ".zprofile intocado" '[ ! -e "$S/home/.zprofile" ]'

echo "2. sem Python"
setup nopy brew node psql pg_isready pg_on
run
check "sai 0" '[ $RC = 0 ]'
check "so instala o Python" '[ "$(brew_calls)" = "brew install python@3.14;" ]'
check "resumo mostra Python instalado" 'grep -q "Python 3.14.0: instalado" "$S/out"'

echo "3. sem Postgres"
setup nopg brew python3 node
run
check "sai 0" '[ $RC = 0 ]'
check "instala, linka e liga o postgresql@16" \
  '[ "$(brew_calls)" = "brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;" ]'
check "confere com select 1" 'grep -q "^psql -w -d postgres -c select 1" "$S/log"'
check "resumo mostra PostgreSQL ligado" 'grep -q "PostgreSQL 16: instalado e ligado" "$S/out"'

echo "4. psql presente e servidor parado"
setup pgoff brew python3 node psql_cellar
run
check "sai 1" '[ $RC = 1 ]'
check "nao chama o brew" '[ -z "$(brew_calls)" ]'
check "informa servidor parado" 'grep -q "servidor nao responde" "$S/out"'
check "da o comando de ligar" 'grep -q "Para resolver: brew services start postgresql@16" "$S/out"'

echo "5. sem brew e sem tty"
setup nobrew node psql pg_isready pg_on
run
check "termina sem travar" '! grep -q TRAVOU "$S/out"'
check "sai 1" '[ $RC = 1 ]'
check "informa falta de terminal" 'grep -q "sem terminal para pedir a senha" "$S/out"'
check "da o comando para o Python" 'grep -q "brew install python@3.14" "$S/out"'

echo "6. TSA_SKIP_PREREQS=1"
setup skip
run TSA_SKIP_PREREQS=1
check "sai 0" '[ $RC = 0 ]'
check "nenhuma chamada registrada" '[ ! -s "$S/log" ]'
check "avisa que pulou" 'grep -q "pulada" "$S/out"'

echo
echo "resultado: $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
