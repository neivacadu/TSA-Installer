#!/bin/bash
# Testa a preparacao do simulador em docs/install.sh sem instalar nada de verdade.
# brew, python3 (e o tsa_editor.py do app por ele), node, psql, pg_isready, xcode-select, ffmpeg, agy, yt-dlp, whisper-cli, auto-editor, capcut-cli, npm,
# curl, hdiutil, ditto e xattr sao falsos e registram cada
# chamada num log. O modelo do whisper tem 4096 bytes no teste, nunca 1,6 GB, e o DMG do
# VoiceStudio tem 2048 bytes: o sha256 conferido e o desses bytes, calculado de verdade.
# O PATH do teste so tem os falsos e utilitarios basicos; HOME e
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
for t in uname dirname basename readlink grep sed sleep cat mkdir cp mv touch chmod mktemp rm id ln head awk find shasum; do
  ln -s "$(command -v "$t")" "$SYSBIN/$t"
done

# sha256 real dos 2048 bytes que o curl falso grava como DMG do VoiceStudio
VS_SHA="$(head -c 2048 /dev/zero | shasum -a 256 | awk '{print $1}')"

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
# o import do PIL so passa depois que o brew instala a formula pillow.
# tsa_editor.py --instalar: FAKE_EDITOR_RC forca o codigo de saida; sem ele, a primeira
# vez instala e grava o estado, e as seguintes respondem que ja esta instalada.
fake python3 '
case "$*" in
  *"tsa_editor.py --instalar "*)
    id="${@: -1}"
    [ -n "${FAKE_EDITOR_RC:-}" ] && exit "$FAKE_EDITOR_RC"
    if [ -e "$FAKE_STATE/editor_$id" ]; then echo "[já instalada] $id"
    else touch "$FAKE_STATE/editor_$id"; echo "[instalada] $id"; fi
    exit 0 ;;
  *python_version*) echo 3.14.0 ;;
  *"import PIL"*) [ -e "$FAKE_STATE/pillow" ] || exit 1 ;;
esac
exit 0'
fake syspython3 'exit 1'
# Python que o WhisperX e o pycaps aceitam (3.10 a 3.12)
fake python3.12 'echo Python 3.12.11'
fake xcode-select 'exit 2'
fake node 'echo v22.0.0'
# a formula ffmpeg do brew vem sem freetype: sem drawtext na lista de filtros
fake ffmpeg '
case "$*" in
  *-filters*) echo " ..C scale            V->V       Scale the input video size." ;;
  *) echo "ffmpeg version 9.0.1" ;;
esac
exit 0'
# a formula ffmpeg-full vem com freetype: essa tem drawtext
fake ffmpeg-full '
case "$*" in
  *-filters*) echo " TC drawtext          V->V       Draw text on top of video frames." ;;
  *) echo "ffmpeg version 9.0.1-full" ;;
esac
exit 0'
fake hdiutil 'case "$1" in
  attach) mkdir -p "$FAKE_VS_VOLUME/VoiceStudio.app/Contents"
    printf "/dev/disk9\tGUID_partition_scheme\t\n/dev/disk9s1\tApple_HFS\t%s\n" "$FAKE_VS_VOLUME" ;;
esac
exit 0'
fake ditto 'cp -R "$1" "$2"'
fake xattr 'exit 0'
fake agy 'case "$*" in *--version*) echo 1.2.5;; esac; exit 0'
fake yt-dlp 'echo 2026.08.19'
fake yt-dlp-velho 'echo 2026.03.03'
fake whisper-cli 'echo whisper 1.7'
fake auto-editor 'echo 31.6.0'
fake auto-editor-velho 'echo 30.1.0'
fake capcut-cli 'echo 0.25.0'
fake capcut-cli-velho 'echo 0.24.0'
# npm falso: so sabe instalar o capcut-cli, e grava o binario ao lado dele no PATH
fake npm '
[ -n "${FAKE_NPMFAIL:-}" ] && exit 1
case "$*" in
  *"install -g capcut-cli@"*) cp "$FAKE_TPL/capcut-cli" "$(dirname "$0")/capcut-cli" ;;
  *) exit 1 ;;
esac'
# curl falso: -I responde conforme FAKE_AGY_URL_OK; o modelo vira um arquivo do tamanho
# de FAKE_MODEL_WRITE; o SHA256SUMS traz o sha de FAKE_VS_SUMS_SHA e o DMG do VoiceStudio
# vira um arquivo de FAKE_VS_DMG_BYTES bytes; os outros -o gravam um instalador falso do agy
fake curl '
case "$*" in
  *-fsSI*) [ "${FAKE_AGY_URL_OK:-1}" = 1 ] ;;
  *SHA256SUMS*)
    prev=""; out=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] || exit 0
    [ "${FAKE_VS_SUMS_OK:-1}" = 1 ] || exit 22
    F="$(printf "\140\140\140")"   # a cerca do markdown, que o awk tem de pular
    { echo "### macOS Apple Silicon artifacts"; echo "$F"
      echo "${FAKE_VS_SUMS_SHA:-${TSA_VS_SHA256:-}}  VoiceStudio_0.5.3_aarch64.dmg"
      echo "$F"; } >"$out"
    ;;
  *VoiceStudio_0.5.3_aarch64.dmg*)
    prev=""; out=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] || exit 0
    head -c "${FAKE_VS_DMG_BYTES:-2048}" /dev/zero >"$out"
    ;;
  *ggml-large-v3-turbo*)
    prev=""; out=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    [ -n "$out" ] || exit 0
    head -c "${FAKE_MODEL_WRITE:-4096}" /dev/zero >"$out"
    ;;
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
    [ -n "${FAKE_BREWFAIL:-}" ] && [ "$2" = "$FAKE_BREWFAIL" ] && exit 1
    case "$2" in
      python@3.14) cp "$FAKE_TPL/python3" "$P/bin/python3"; cp "$FAKE_TPL/python3" "$P/bin/python3.14" ;;
      python@3.12) mkdir -p "$P/opt/python@3.12/bin"
        cp "$FAKE_TPL/python3.12" "$P/opt/python@3.12/bin/python3.12"; cp "$FAKE_TPL/python3.12" "$P/bin/python3.12" ;;
      node) cp "$FAKE_TPL/node" "$P/bin/node" ;;
      ffmpeg) cp "$FAKE_TPL/ffmpeg" "$P/bin/ffmpeg" ;;
      ffmpeg-full) mkdir -p "$P/opt/ffmpeg-full/bin"
        cp "$FAKE_TPL/ffmpeg-full" "$P/opt/ffmpeg-full/bin/ffmpeg" ;;
      pillow) touch "$FAKE_STATE/pillow" ;;
      yt-dlp) cp "$FAKE_TPL/yt-dlp" "$P/bin/yt-dlp" ;;
      whisper-cpp) cp "$FAKE_TPL/whisper-cli" "$P/bin/whisper-cli" ;;
      auto-editor) cp "$FAKE_TPL/auto-editor" "$P/bin/auto-editor" ;;
      --cask) [ -n "${FAKE_CASKFAIL:-}" ] && exit 1
        case "$3" in handy) mkdir -p "$FAKE_HANDY_APP" ;; esac ;;
      postgresql@16) mkdir -p "$P/opt/postgresql@16/bin"
        cp "$FAKE_TPL/psql" "$FAKE_TPL/pg_isready" "$FAKE_TPL/createdb" "$P/opt/postgresql@16/bin/" ;;
    esac ;;
  outdated) [ -e "$FAKE_STATE/ytdlp_velho" ] && echo "$2 (2026.03.03) < 2026.08.19" ;;
  upgrade) q="$(command -v "$2" 2>/dev/null)"; [ -n "$q" ] && cp "$FAKE_TPL/$2" "$q"
    rm -f "$FAKE_STATE/ytdlp_velho" ;;
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
  mkdir -p "$S/userbin" "$S/prefix/bin" "$S/prefix/opt" "$S/state" "$S/home" "$S/Applications"
  : >"$S/log"
  BREW_ON_PATH=1
  RUNS=0
  local b
  for b in "$@"; do
    case "$b" in
      pg_on) touch "$S/state/pg_running" ;;
      brew) cp "$TPL/brew" "$S/prefix/bin/brew" ;;
      agy_login) mkdir -p "$S/home/.gemini"; echo '{"token":"falso"}' >"$S/home/.gemini/oauth_creds.json" ;;
      agy_login_novo) mkdir -p "$S/home/.gemini/antigravity-cli"; echo 'falso' >"$S/home/.gemini/antigravity-cli/antigravity-oauth-token" ;;
      handy) mkdir -p "$S/Applications/Handy.app" ;;
      voicestudio) mkdir -p "$S/Applications/VoiceStudio.app" ;;
      pillow) touch "$S/state/pillow" ;;
      py312_keg) mkdir -p "$S/prefix/opt/python@3.12/bin"
        cp "$TPL/python3.12" "$S/prefix/opt/python@3.12/bin/python3.12" ;;
      ffmpeg_drawtext) cp "$TPL/ffmpeg-full" "$S/userbin/ffmpeg" ;;
      ffmpeg_full_keg) mkdir -p "$S/prefix/opt/ffmpeg-full/bin"
        cp "$TPL/ffmpeg-full" "$S/prefix/opt/ffmpeg-full/bin/ffmpeg" ;;
      autoeditor_velho) cp "$TPL/auto-editor-velho" "$S/userbin/auto-editor" ;;
      capcut_velho) cp "$TPL/capcut-cli-velho" "$S/userbin/capcut-cli" ;;
      ytdlp_velho) cp "$TPL/yt-dlp-velho" "$S/userbin/yt-dlp"; touch "$S/state/ytdlp_velho" ;;
      modelo|modelo_errado)
        mkdir -p "$S/home/.cache/whisper"
        head -c "$([ "$b" = modelo ] && echo 4096 || echo 99)" /dev/zero \
          >"$S/home/.cache/whisper/ggml-large-v3-turbo.bin" ;;
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
    FAKE_LOG="$S/log" FAKE_STATE="$S/state" FAKE_TPL="$TPL" FAKE_HANDY_APP="$S/Applications/Handy.app" \
    TSA_ONLY_PREREQS=1 TSA_TTY=/nonexistent/tty TSA_BREW_CANDIDATES="$cand" TSA_PG_WAIT=3 \
    TSA_PG_PORT="$PORT_FREE" TSA_POSTGRES_APP="$S/Postgres.app" TSA_SYS_PYTHON=/nonexistent/python3 \
    TSA_HANDY_APP="$S/Applications/Handy.app" TSA_WHISPER_MODEL_BYTES=4096 \
    FAKE_VS_VOLUME="$S/volume" TSA_VS_APP="$S/Applications/VoiceStudio.app" \
    TSA_VS_BASE_URL="https://exemplo.invalido/voicestudio" TSA_VS_SHA256="$VS_SHA" \
    TSA_EDITOR_PY_ROOTS="$S/prefix/opt" \
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
setup all brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "sai 0" '[ $RC = 0 ]'
check "so consulta se o yt-dlp esta velho" '[ "$(brew_calls)" = "brew outdated yt-dlp;" ]'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'
check "resumo: auto-editor pronto" 'out_has "auto-editor 31.6.0: ja estava pronto"'
check "resumo: capcut-cli pronto" 'out_has "capcut-cli 0.25.0: ja estava pronto"'
check "fim: aponta o tsa-editor --estado" 'out_has "rode tsa-editor --estado"'
check ".zprofile intocado" '[ ! -e "$S/home/.zprofile" ]'

echo "2. sem Python"
setup nopy brew node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "sai 0" '[ $RC = 0 ]'
check "so instala o Python" '[ "$(brew_changes)" = "brew install python@3.14;" ]'
check "resumo mostra Python instalado" 'out_has "Python 3.14.0: instalado"'

echo "3. sem Postgres"
setup nopg brew python3 node ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "sai 0" '[ $RC = 0 ]'
check "instala, linka e liga o postgresql@16" \
  '[ "$(brew_changes)" = "brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;" ]'
check "confere com select 1" 'grep -q "^psql -w -d postgres -c select 1" "$S/log"'
check "confere a versao do servidor" 'grep -q "server_version_num" "$S/log"'
check "resumo mostra PostgreSQL ligado" 'out_has "PostgreSQL 16: instalado e ligado"'

echo "4. psql presente e servidor parado"
setup pgoff brew python3 node psql_cellar ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "sai 1" '[ $RC = 1 ]'
check "nao muda nada pelo brew" '[ -z "$(brew_changes)" ]'
check "informa servidor parado" 'out_has "servidor nao responde"'
check "da o comando de ligar" 'out_has "Para resolver: brew services start postgresql@16"'

echo "5. sem brew e sem tty"
setup nobrew node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio
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
setup offpath brew node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
BREW_ON_PATH=0
run2
check "1a: sai 0 e instala so o Python" '[ $RC1 = 0 ] && [ "$(brew_changes "$S/log1")" = "brew install python@3.14;" ]'
check "2a: sai 0 e nao instala nada" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'
check "2a: acha o Python do brew" 'out_has "Python 3.14.0: ja estava pronto"'
check ".zprofile com uma linha do shellenv" '[ "$(zcount "brew shellenv")" = 1 ]'

echo "8. postgresql@16 ja instalado sem link, duas execucoes"
setup keg brew python3 node keg16 pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao instala nem linka" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "resumo diz ligado" 'out_has "PostgreSQL: ja estava ligado"'
check ".zprofile com uma linha do keg" '[ "$(zcount "opt/postgresql@16/bin")" = 1 ]'

echo "9. conflito no brew link, duas execucoes"
setup linkfail brew python3 node ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2 FAKE_LINKFAIL=1
check "1a: instala, tenta o link e liga" \
  '[ "$(brew_changes "$S/log1")" = "brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;" ]'
check "1a: avisa o conflito e termina ligado" 'grep -q "deu conflito" "$S/out1" && grep -q "instalado e ligado" "$S/out1"'
check "2a: nao instala nem linka" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'
check ".zprofile com uma linha do keg" '[ "$(zcount "opt/postgresql@16/bin")" = 1 ]'

echo "10. /usr/bin/python3 sem Command Line Tools, duas execucoes"
setup noclt brew node psql pg_isready pg_on xcode-select ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
cp "$TPL/syspython3" "$S/userbin/python3"
run2 TSA_SYS_PYTHON="$S/userbin/python3"
check "1a: nao executa o python do sistema" '! grep -q "^syspython3" "$S/log1"'
check "1a: consulta o xcode-select" 'grep -q "^xcode-select" "$S/log1"'
check "1a: instala o Python" '[ "$(brew_changes "$S/log1")" = "brew install python@3.14;" ]'
check "2a: nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "11. porta 5432 ocupada sem psql, duas execucoes"
setup port brew python3 node ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
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
setup pgapp brew python3 node ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
mkdir -p "$S/Postgres.app/Contents/Versions/latest/bin"
cp "$TPL/psql" "$S/Postgres.app/Contents/Versions/latest/bin/"
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "informa o app e o caminho real" 'out_has "Postgres.app/Contents/Versions/latest/bin"'
check ".zprofile intocado" '[ ! -e "$S/home/.zprofile" ]'

echo "13. outra versao do brew sem link (postgresql@14), duas execucoes"
setup keg14 brew python3 node keg14 ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check "informa o caminho do keg" 'out_has "opt/postgresql@14/bin"'
check "da o comando de ligar" 'out_has "brew services start postgresql@14"'

echo "14. servidor que responde nao e o 16"
setup otherver brew python3 node ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run FAKE_PG_VERSION=150008
check "sai 1" '[ $RC = 1 ]'
check "nao diz instalado e ligado" '! out_has "instalado e ligado"'
check "informa outro servidor" 'out_has "quem respondeu foi outro servidor (versao 150008)"'

echo "15. faltando tudo, segunda execucao nao reinstala"
setup again brew curl hdiutil ditto xattr agy_login modelo
run2
check "1a: instala Python, Node, PostgreSQL, ffmpeg, ffmpeg-full, pillow, auto-editor, yt-dlp, whisper-cpp e Handy" \
  '[ "$(brew_changes "$S/log1")" = "brew install python@3.14;brew install node;brew install postgresql@16;brew link --force postgresql@16;brew services start postgresql@16;brew install ffmpeg;brew install ffmpeg-full;brew install pillow;brew install auto-editor;brew install yt-dlp;brew install whisper-cpp;brew install --cask handy;" ]'
check "1a: instala o agy pelo instalador oficial" '[ -x "$S/home/.local/bin/agy" ]'
check "1a: instala o VoiceStudio" '[ -d "$S/Applications/VoiceStudio.app" ]'
check "1a: nao baixa o modelo, que ja estava pronto" '! grep -q "ggml-large-v3-turbo" "$S/log1"'
check "2a: sai 0 sem mudar nada nem chamar o curl" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ] && ! grep -q "^curl" "$S/log"'

echo "16. ffmpeg e agy presentes, com login, duas execucoes"
setup midiaok brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao muda nada pelo brew nem chama o curl" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ] && ! grep -q "^curl" "$S/log1" "$S/log"'
check "resumo: ffmpeg pronto" 'out_has "ffmpeg: ja estava pronto"'
check "resumo: agy com login" 'out_has "Antigravity agy 1.2.5: ja estava pronto, com login feito"'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'

echo "17. agy presente e sem login, duas execucoes"
setup semlogin brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ] && ! grep -q "^curl" "$S/log"'
check "resumo: sem login" 'out_has "Antigravity agy 1.2.5: ja estava pronto, mas sem login."'
check "resumo: instrucao de login" 'out_has "escolha Google OAuth"'
check "resumo: aviso da janela" 'out_has "campo do codigo fica escondido"'

echo "18. sem ffmpeg, duas execucoes"
setup noff brew python3 node psql pg_isready pg_on agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "1a: instala o ffmpeg e, atras dele, a ffmpeg-full do drawtext" \
  '[ "$(brew_changes "$S/log1")" = "brew install ffmpeg;brew install ffmpeg-full;" ]'
check "1a: resumo diz instalado" 'grep -q "ffmpeg: instalado" "$S/out1"'
check "2a: nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "19. sem agy, duas execucoes"
setup noagy brew python3 node psql pg_isready pg_on ffmpeg_drawtext curl agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "1a: confere o endereco antes de baixar" 'grep -q "^curl -fsSI" "$S/log1"'
check "1a: baixa e roda o instalador oficial" 'grep -q "^curl -fsSL" "$S/log1" && [ -x "$S/home/.local/bin/agy" ]'
check "1a: resumo diz instalado com login" 'grep -q "Antigravity agy 1.2.5: instalado, com login feito" "$S/out1"'
check "1a: nao usa o brew para o agy" '[ -z "$(brew_changes "$S/log1")" ]'
check "2a: acha em ~/.local/bin sem baixar" '[ $RC2 = 0 ] && ! grep -q "^curl" "$S/log"'
check ".zprofile com uma linha do ~/.local/bin" '[ "$(zcount ".local/bin")" = 1 ]'

echo "20. sem agy e endereco fora do ar, duas execucoes"
setup agyoff brew python3 node psql pg_isready pg_on ffmpeg_drawtext curl yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2 FAKE_AGY_URL_OK=0
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "confere o endereco e nao baixa" 'grep -q "^curl -fsSI" "$S/log1" && ! grep -q "^curl -fsSL" "$S/log1"'
check "nao instala nada" '[ -z "$(brew_changes "$S/log1")" ] && [ ! -e "$S/home/.local/bin/agy" ]'
check "resumo informa o endereco" 'out_has "nao respondeu 200"'

echo "21. esteira de video pronta, duas execucoes"
setup videook brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao muda nada pelo brew nem chama o curl" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ] && ! grep -q "^curl" "$S/log1" "$S/log"'
check "resumo: yt-dlp pronto" 'out_has "yt-dlp 2026.08.19: ja estava pronto"'
check "resumo: whisper-cli pronto" 'out_has "whisper-cli: ja estava pronto"'
check "resumo: modelo pronto" 'out_has "Modelo ggml-large-v3-turbo.bin: ja estava pronto"'
check "resumo: Handy pronto" 'out_has "Handy (ditado por microfone): ja estava pronto"'
check "resumo: permissao do Handy" 'out_has "conceda Microfone e Acessibilidade"'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'

echo "22. sem yt-dlp, duas execucoes"
setup noyt brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "1a: instala so o yt-dlp" '[ "$(brew_changes "$S/log1")" = "brew install yt-dlp;" ]'
check "1a: resumo diz instalado" 'grep -q "yt-dlp 2026.08.19: instalado" "$S/out1"'
check "2a: sai 0 e nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "23. sem whisper-cli, duas execucoes"
setup nowhisper brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "1a: instala so o whisper-cpp" '[ "$(brew_changes "$S/log1")" = "brew install whisper-cpp;" ]'
check "1a: resumo diz instalado" 'grep -q "whisper-cli: instalado" "$S/out1"'
check "2a: sai 0 e nao reinstala" '[ $RC2 = 0 ] && [ -z "$(brew_changes)" ]'

echo "24. modelo ausente na conferencia: avisa e nao baixa"
setup semmodelo brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli curl handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 1 nas duas" '[ $RC1 = 1 ] && [ $RC2 = 1 ]'
check "nao baixa nada" '! grep -q "ggml-large-v3-turbo" "$S/log1" "$S/log"'
check "nao deixa arquivo no cache" '[ ! -e "$S/home/.cache/whisper/ggml-large-v3-turbo.bin" ]'
check "informa o tamanho" 'out_has "sao 1,6 GB"'
check "da o comando para baixar depois" 'out_has "TSA_BAIXAR_MODELO=1 bash"'

echo "25. modelo ausente com TSA_BAIXAR_MODELO=1, duas execucoes"
setup baixamodelo brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli curl handy pillow voicestudio auto-editor capcut-cli
run2 TSA_BAIXAR_MODELO=1
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: avisa o tamanho antes de baixar" 'grep -q "1,6 GB (4096 bytes) para baixar" "$S/out1"'
check "1a: avisa o tempo estimado" 'grep -q "3 min a 10 MB/s" "$S/out1"'
check "1a: baixa retomando e para arquivo parcial" \
  'grep -q "continue-at - .*ggml-large-v3-turbo.bin -o .*ggml-large-v3-turbo.bin.parcial" "$S/log1"'
check "1a: modelo com o tamanho certo e sem sobra parcial" \
  '[ "$(/usr/bin/stat -f %z "$S/home/.cache/whisper/ggml-large-v3-turbo.bin")" = 4096 ] &&
   [ ! -e "$S/home/.cache/whisper/ggml-large-v3-turbo.bin.parcial" ]'
check "1a: resumo diz baixado" 'grep -q "Modelo ggml-large-v3-turbo.bin: baixado" "$S/out1"'
check "2a: nao baixa de novo" '! grep -q "ggml-large-v3-turbo" "$S/log"'

echo "26. modelo com tamanho errado"
setup modelotorto brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli curl handy modelo_errado pillow voicestudio auto-editor capcut-cli
run
check "1a: sai 1 e avisa o tamanho errado" '[ $RC = 1 ] && out_has "tem 99 bytes e o certo sao 4096"'
check "1a: apaga o arquivo errado e nao baixa" \
  '[ ! -e "$S/home/.cache/whisper/ggml-large-v3-turbo.bin" ] && ! grep -q "ggml-large-v3-turbo" "$S/log"'
run TSA_BAIXAR_MODELO=1
check "2a: rebaixa e fica com o tamanho certo" \
  '[ $RC = 0 ] && [ "$(/usr/bin/stat -f %z "$S/home/.cache/whisper/ggml-large-v3-turbo.bin")" = 4096 ]'

echo "27. download cortado no meio"
setup modelocurto brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli curl handy pillow voicestudio auto-editor capcut-cli
run TSA_BAIXAR_MODELO=1 FAKE_MODEL_WRITE=10
check "sai 1" '[ $RC = 1 ]'
check "nao renomeia o parcial" '[ ! -e "$S/home/.cache/whisper/ggml-large-v3-turbo.bin" ]'
check "guarda o pedaco baixado" '[ -e "$S/home/.cache/whisper/ggml-large-v3-turbo.bin.parcial" ]'
check "avisa o download incompleto" 'out_has "Download incompleto: 10 de 4096 bytes"'
check "diz que retoma de onde parou" 'out_has "retoma de onde parou"'

echo "28. sem Handy, duas execucoes"
setup nohandy brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: instala so o Handy pelo cask" '[ "$(brew_changes "$S/log1")" = "brew install --cask handy;" ]'
check "1a: resumo diz instalado" 'grep -q "Handy (ditado por microfone): instalado" "$S/out1"'
check "1a: resumo pede as permissoes" 'grep -q "conceda Microfone e Acessibilidade" "$S/out1"'
check "2a: nao reinstala" '[ -z "$(brew_changes)" ]'

echo "29. Handy nao instala: aviso que nao bloqueia"
setup handyfail brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo pillow voicestudio auto-editor capcut-cli
run FAKE_CASKFAIL=1
check "sai 0 mesmo assim" '[ $RC = 0 ]'
check "resumo ainda diz tudo pronto" 'out_has "Tudo pronto"'
check "avisa a falha do Handy" 'out_has "Handy (ditado por microfone): a instalacao falhou."'
check "da o comando do cask" 'out_has "brew install --cask handy"'
check "nao vira pendencia" '! out_has "Falta resolver"'

echo "30. yt-dlp presente mas velho, duas execucoes"
setup ytvelho brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login ytdlp_velho whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: so atualiza o yt-dlp" '[ "$(brew_changes "$S/log1")" = "brew upgrade yt-dlp;" ]'
check "1a: resumo diz atualizado e a versao velha" \
  'grep -q "yt-dlp 2026.08.19: atualizado (a versao anterior era 2026.03.03)" "$S/out1"'
check "1a: explica o erro 403" 'grep -q "erro 403 no YouTube" "$S/out1"'
check "2a: consulta e nao atualiza de novo" \
  '[ "$(brew_calls)" = "brew outdated yt-dlp;" ] && [ -z "$(brew_changes)" ]'
check "2a: resumo diz ja estava pronto" 'out_has "yt-dlp 2026.08.19: ja estava pronto"'

echo "31. ffmpeg sem drawtext: instala a ffmpeg-full, duas execucoes"
setup nodrawtext brew python3 node psql pg_isready pg_on ffmpeg agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: nao reinstala o ffmpeg, so acrescenta a ffmpeg-full" \
  '[ "$(brew_changes "$S/log1")" = "brew install ffmpeg-full;" ]'
check "1a: resumo diz de onde veio o drawtext" \
  'grep -q "ffmpeg com o filtro drawtext: instalado pela formula ffmpeg-full" "$S/out1"'
check "2a: acha o keg e nao reinstala" '[ -z "$(brew_changes)" ]'
check ".zprofile com uma linha do keg da ffmpeg-full" '[ "$(zcount "opt/ffmpeg-full/bin")" = 1 ]'
check "resumo ainda diz tudo pronto" 'out_has "Tudo pronto"'

echo "32. ffmpeg-full ja instalada sem link, duas execucoes"
setup drawtextkeg brew python3 node psql pg_isready pg_on ffmpeg ffmpeg_full_keg agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nunca instala nada" '[ -z "$(brew_changes "$S/log1")$(brew_changes)" ]'
check ".zprofile com uma linha do keg da ffmpeg-full" '[ "$(zcount "opt/ffmpeg-full/bin")" = 1 ]'

echo "33. sem brew e sem drawtext: avisa e nao vira pendencia"
setup drawtextnobrew python3 node psql pg_isready pg_on ffmpeg yt-dlp whisper-cli modelo handy pillow voicestudio agy agy_login
run
check "avisa a falta do drawtext" 'out_has "ffmpeg sem o filtro drawtext"'
check "explica a saida pelo pillow" 'out_has "o texto sai como imagem pelo pillow"'
check "nao conta como pendencia do drawtext" '! grep -q "✗ ffmpeg sem o filtro drawtext" "$OUT"'

echo "34. sem pillow, duas execucoes"
setup nopillow brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy voicestudio auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: instala so o pillow" '[ "$(brew_changes "$S/log1")" = "brew install pillow;" ]'
check "1a: resumo diz instalado e em qual Python" 'grep -q "pillow (texto como imagem): instalado (" "$S/out1"'
check "2a: nao reinstala" '[ -z "$(brew_changes)" ]'
check "2a: resumo diz ja estava pronto" 'out_has "pillow (texto como imagem): ja estava pronto"'

echo "35. VoiceStudio ja instalado: nao baixa nada"
setup vsok brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio curl hdiutil ditto xattr auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "nao chama curl nem hdiutil" '! grep -qE "^(curl|hdiutil|ditto)" "$S/log1" "$S/log"'
check "resumo diz pronto" 'out_has "VoiceStudio (clonagem de voz e dublagem): ja estava pronto"'
check "avisa o ambiente Python do primeiro uso" 'out_has "ambiente Python de cerca de 1,8 GB"'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'

echo "36. sem VoiceStudio: confere o sha256 duas vezes e instala, duas execucoes"
setup vsnovo brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow curl hdiutil ditto xattr auto-editor capcut-cli
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: baixa o SHA256SUMS antes do DMG" \
  'grep -n "SHA256SUMS-macOS.Apple.Silicon.txt" "$S/log1" >"$S/a" &&
   grep -n "VoiceStudio_0.5.3_aarch64.dmg -o" "$S/log1" >"$S/b" &&
   [ "$(head -1 "$S/a" | sed "s/:.*//")" -lt "$(head -1 "$S/b" | sed "s/:.*//")" ]'
check "1a: diz que conferiu nos dois lugares" 'grep -q "sha256 conferido na release e no arquivo" "$S/out1"'
check "1a: instala o app e tira a quarentena" \
  '[ -d "$S/Applications/VoiceStudio.app" ] && grep -q "^xattr -dr com.apple.quarantine" "$S/log1"'
check "1a: resumo diz instalado, com o primeiro uso e o Gatekeeper" \
  'grep -q "VoiceStudio (clonagem de voz e dublagem): instalado em" "$S/out1" &&
   grep -q "ambiente Python de cerca de 1,8 GB" "$S/out1" &&
   grep -q "assinado ad-hoc, sem Team ID da Apple" "$S/out1"'
check "1a: nao usa o brew para o VoiceStudio" '[ -z "$(brew_changes "$S/log1")" ]'
check "2a: acha instalado e nao baixa de novo" '! grep -qE "^(curl|hdiutil|ditto)" "$S/log"'

echo "37. sha256 divergente na release: recusa antes de baixar o DMG"
setup vssha brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow curl hdiutil ditto xattr auto-editor capcut-cli
run FAKE_VS_SUMS_SHA=0000000000000000000000000000000000000000000000000000000000000000
check "nao baixa o DMG" '! grep -q "VoiceStudio_0.5.3_aarch64.dmg -o" "$S/log"'
check "nao instala o app" '[ ! -e "$S/Applications/VoiceStudio.app" ]'
check "diz qual sha256 a release publicou" \
  'out_has "o sha256 de VoiceStudio_0.5.3_aarch64.dmg na release (0000000000000000000000000000000000000000000000000000000000000000) nao e o que a TSA conferiu"'
check "alerta sobre a copia falsa" 'out_has "existe copia falsa deste projeto com malware"'
check "nao vira pendencia" '! out_has "Falta resolver"'

echo "38. DMG adulterado: recusa depois de baixar"
setup vsdmg brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow curl hdiutil ditto xattr auto-editor capcut-cli
run FAKE_VS_DMG_BYTES=1024
check "baixa o DMG e nao monta" \
  'grep -q "VoiceStudio_0.5.3_aarch64.dmg -o" "$S/log" && ! grep -q "^hdiutil" "$S/log"'
check "nao instala o app" '[ ! -e "$S/Applications/VoiceStudio.app" ]'
check "avisa que o arquivo nao bateu" 'out_has "o sha256 do arquivo baixado"'
check "diz que apagou o DMG" 'out_has "apaguei o DMG e nao instalei"'
check "nao vira pendencia" '! out_has "Falta resolver"'

echo "39. release sem o SHA256SUMS: nao baixa nada"
setup vssemsums brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow curl hdiutil ditto xattr auto-editor capcut-cli
run FAKE_VS_SUMS_OK=0
check "nao baixa o DMG nem instala" \
  '! grep -q "VoiceStudio_0.5.3_aarch64.dmg -o" "$S/log" && [ ! -e "$S/Applications/VoiceStudio.app" ]'
check "informa o arquivo que faltou" 'out_has "SHA256SUMS-macOS.Apple.Silicon.txt da release v0.5.3 nao baixou"'
check "manda baixar so do endereco oficial" 'out_has "github.com/debpalash/VoiceStudio/releases"'
check "nao vira pendencia" '! out_has "Falta resolver"'

echo "40. sem auto-editor e sem capcut-cli, duas execucoes"
setup avnovo brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio npm
run2
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: instala so o auto-editor pelo brew" '[ "$(brew_changes "$S/log1")" = "brew install auto-editor;" ]'
check "1a: instala o capcut-cli na versao fixada" 'grep -q "^npm install -g capcut-cli@0.25.0" "$S/log1"'
check "1a: resumo diz os dois instalados" \
  'grep -q "auto-editor 31.6.0: instalado" "$S/out1" && grep -q "capcut-cli 0.25.0: instalado$" "$S/out1"'
check "2a: nao reinstala nenhum" '[ -z "$(brew_changes)" ] && ! grep -q "^npm install -g capcut-cli" "$S/log"'
check "2a: resumo diz os dois prontos" \
  'out_has "auto-editor 31.6.0: ja estava pronto" && out_has "capcut-cli 0.25.0: ja estava pronto"'

echo "41. auto-editor e capcut-cli em outra versao"
setup avvelho brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio npm autoeditor_velho capcut_velho
run
check "sai 0" '[ $RC = 0 ]'
check "auto-editor: nao mexe pelo brew" '[ -z "$(brew_changes)" ]'
check "auto-editor: avisa a versao conferida" 'out_has "auto-editor 30.1.0: a versao conferida pela TSA e a 31.6.0."'
check "capcut-cli: troca para a versao fixada" \
  'grep -q "^npm install -g capcut-cli@0.25.0" "$S/log" && out_has "capcut-cli 0.25.0: instalado (a versao anterior era 0.24.0)"'

echo "42. auto-editor e capcut-cli falham: aviso que nao bloqueia"
setup avfalha brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio npm
run FAKE_BREWFAIL=auto-editor FAKE_NPMFAIL=1
check "sai 0 mesmo assim" '[ $RC = 0 ]'
check "resumo ainda diz tudo pronto" 'out_has "Tudo pronto"'
check "avisa a falha do auto-editor" 'out_has "auto-editor: a instalacao falhou" && out_has "Para resolver: brew install auto-editor"'
check "avisa a falha do capcut-cli" 'out_has "capcut-cli: a instalacao falhou" && out_has "Para resolver: npm install -g capcut-cli@0.25.0"'
check "nao vira pendencia" '! out_has "Falta resolver"'

echo "43. sem npm e sem brew: capcut-cli e auto-editor viram aviso"
setup avsemnada python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio
run
check "capcut-cli: avisa que falta o npm" 'out_has "capcut-cli: npm nao encontrado"'
check "auto-editor: manda instalar o Homebrew" 'out_has "instale o Homebrew e rode: brew install auto-editor"'
check "a unica pendencia e o Homebrew" \
  'out_has "Falta resolver 1 item" && out_has "✗ Homebrew" && ! grep -qE "✗ (auto-editor|capcut-cli)" "$OUT"'

# Editor de video: WhisperX e pycaps pelo tsa_editor.py do app, so para quem responde sim.
BASE="brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli"
TUDO="$BASE python3.12"   # 44 a 48 presumem um Python que o tsa_editor aceita
PERGUNTA="Você edita vídeo (Premiere Pro ou CapCut)? [s/N]"
# app falso com o tsa_editor.py; $1 e a resposta que o terminal falso vai dar
editor_setup(){
  mkdir -p "$S/TSA.app/Contents/Resources/tsa/corte"
  : >"$S/TSA.app/Contents/Resources/tsa/corte/tsa_editor.py"
  printf '%s\n' "$1" >"$S/tty"
  ED="TSA_EDITOR_PY=$S/TSA.app/Contents/Resources/tsa/corte/tsa_editor.py"
}
perguntou(){ grep -qF "$PERGUNTA" "${1:-$OUT}"; }
editor_calls(){ grep -o 'tsa_editor.py --instalar [a-z]*' "${1:-$S/log}" | tr '\n' ';'; }
guardado(){ cat "$S/home/.config/tsa/editor-video" 2>/dev/null; }
DOIS="tsa_editor.py --instalar whisperx;tsa_editor.py --instalar pycaps;"

echo "44. edita video (resposta s): instala os dois e nao pergunta de novo"
setup edsim $TUDO
editor_setup s
run2 "$ED" TSA_TTY="$S/tty"
check "sai 0 nas duas" '[ $RC1 = 0 ] && [ $RC2 = 0 ]'
check "1a: pergunta" 'perguntou "$S/out1"'
check "1a: avisa tempo e tamanho antes" 'grep -q "25 minutos" "$S/out1" && grep -q "3 GB" "$S/out1"'
check "1a: instala whisperx e depois pycaps" '[ "$(editor_calls "$S/log1")" = "$DOIS" ]'
check "guarda sim" '[ "$(guardado)" = sim ]'
check "2a: nao pergunta de novo" '! perguntou'
check "2a: o tsa_editor responde ja instalada" 'out_has "\[já instalada\] whisperx" && out_has "\[já instalada\] pycaps"'
check "resumo: os dois prontos" 'out_has "whisperx: pronto" && out_has "pycaps: pronto"'

echo "45. nao edita video (resposta n): nao instala; a resposta guardada vale depois"
setup ednao $TUDO
editor_setup n
run "$ED" TSA_TTY="$S/tty"
check "sai 0" '[ $RC = 0 ]'
check "pergunta" 'perguntou'
check "nao chama o tsa_editor" '[ -z "$(editor_calls)" ]'
check "guarda nao" '[ "$(guardado)" = nao ]'
check "resumo diz como mudar" 'out_has "TSA_EDITOR_VIDEO=sim"'
printf 's\n' >"$S/tty"
run "$ED" TSA_TTY="$S/tty"
check "2a: terminal responderia s, mas nao pergunta" '! perguntou'
check "2a: continua sem instalar" '[ -z "$(editor_calls)" ]'

echo "46. sem terminal: nao instala, nao trava e nao guarda"
setup edsemtty $TUDO
editor_setup s
run "$ED"
check "termina sem travar e sai 0" '! out_has TRAVOU && [ $RC = 0 ]'
check "nao pergunta" '! perguntou'
check "nao chama o tsa_editor" '[ -z "$(editor_calls)" ]'
check "nao guarda resposta" '[ ! -e "$S/home/.config/tsa/editor-video" ]'

echo "47. TSA_EDITOR_VIDEO sobrepoe a resposta guardada e a pergunta"
setup edenv $TUDO
editor_setup n
mkdir -p "$S/home/.config/tsa"; echo nao >"$S/home/.config/tsa/editor-video"
run "$ED" TSA_TTY="$S/tty" TSA_EDITOR_VIDEO=sim
check "sim: nao pergunta e instala os dois" '! perguntou && [ "$(editor_calls)" = "$DOIS" ]'
check "sim: passa a ser a resposta guardada" '[ "$(guardado)" = sim ]'
: >"$S/log"
run "$ED" TSA_TTY="$S/tty" TSA_EDITOR_VIDEO=nao
check "nao: nao instala" '[ -z "$(editor_calls)" ] && [ "$(guardado)" = nao ]'

echo "48. tsa_editor falha, falta requisito ou nao existe: aviso que nao bloqueia"
setup edfalha $TUDO
editor_setup s
run "$ED" TSA_TTY="$S/tty" FAKE_EDITOR_RC=2
check "falhou: sai 0 e tudo pronto" '[ $RC = 0 ] && out_has "Tudo pronto" && ! out_has "Falta resolver"'
check "falhou: tenta os dois" '[ "$(editor_calls)" = "$DOIS" ]'
check "falhou: avisa com o comando" 'out_has "whisperx: a instalacao falhou (codigo 2)" && out_has "Para resolver: tsa-editor --instalar pycaps"'
run "$ED" TSA_TTY="$S/tty" FAKE_EDITOR_RC=1
check "falta requisito: aviso, sai 0" '[ $RC = 0 ] && out_has "pycaps: nao instalado, falta um requisito" && ! out_has "Falta resolver"'
rm -f "$S/TSA.app/Contents/Resources/tsa/corte/tsa_editor.py"
run "$ED" TSA_TTY="$S/tty"
check "sem tsa_editor.py: aviso, sai 0" '[ $RC = 0 ] && out_has "nao achei o tsa_editor.py" && ! out_has "Falta resolver"'

echo "49. sem Python 3.10 a 3.12: instala o python@3.12 antes do tsa_editor"
setup edpy $BASE
editor_setup s
run "$ED" TSA_EDITOR_VIDEO=sim
check "sai 0" '[ $RC = 0 ]'
check "instala so o python@3.12 pelo brew" '[ "$(brew_changes)" = "brew install python@3.12;" ]'
check "depois roda o tsa_editor nos dois" '[ "$(editor_calls)" = "$DOIS" ]'
check "o brew vem antes do tsa_editor" \
  '[ "$(grep -nE "^brew install python@3.12|tsa_editor.py --instalar" "$S/log" | head -1 | grep -c "brew install")" = 1 ]'

echo "50. brew falha no python@3.12: aviso, sem tsa_editor"
setup edpyfalha $BASE
editor_setup s
run "$ED" TSA_EDITOR_VIDEO=sim FAKE_BREWFAIL=python@3.12
check "sai 0 e nao vira pendencia" '[ $RC = 0 ] && ! out_has "Falta resolver"'
check "tentou o python@3.12" 'grep -q "^brew install python@3.12" "$S/log"'
check "nao chama o tsa_editor" '[ -z "$(editor_calls)" ]'
check "avisa com o comando" 'out_has "nao consegui instalar o Python 3.12" && out_has "Para resolver: brew install python@3.12"'

echo "51. Python 3.12 ja no keg do brew: nao reinstala"
setup edpyok $BASE py312_keg
editor_setup s
run "$ED" TSA_EDITOR_VIDEO=sim
check "sai 0" '[ $RC = 0 ]'
check "nao chama brew install python@3.12" '! grep -q "^brew install python@3.12" "$S/log"'
check "roda o tsa_editor nos dois" '[ "$(editor_calls)" = "$DOIS" ]'

echo
echo "52. agy 1.2 logado pelo antigravity-oauth-token: sem pendencia"
setup agynovo brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy agy_login_novo yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "sai 0" '[ $RC = 0 ]'
check "resumo diz tudo pronto" 'out_has "Tudo pronto"'
check "nao pede o login do agy" '! out_has "mas sem login"'

echo "53. agy sem nenhum login: pendencia, mas o resto funciona"
setup agysem brew python3 node psql pg_isready pg_on ffmpeg_drawtext agy yt-dlp whisper-cli modelo handy pillow voicestudio auto-editor capcut-cli
run
check "pede o login do agy" 'out_has "mas sem login"'
check "diz que so a leitura de video e o Operacional esperam" 'out_has "so a leitura de video pelo Gemini e o ACE Operacional esperam"'
check "nao diz mais que o simulador nao roda" '! out_has "simulador ACE so roda"'

echo "resultado: $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
