#!/usr/bin/env bash
# Instalador do TSA (macOS) — comando unico, sem GitHub CLI e sem conta no GitHub.
#   curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | bash
# 1. Baixa o app do release publico, confere o SHA-256, instala e remove a quarentena.
#    O DNA da TSA ja vai embutido e assinado dentro do app.
# 2. Prepara o Mac para o simulador ACE: Python 3.10+, Node e PostgreSQL ligado.
#    So instala o que falta, via Homebrew. Falha aqui nao desfaz o app.
# Controles:
#   TSA_SKIP_PREREQS=1  instala so o app, sem preparar o simulador.
#   TSA_ONLY_PREREQS=1  so prepara o simulador, sem baixar nem instalar o app.
# O script inteiro fica dentro de main(): com curl | bash, o bash le tudo antes de rodar.
set -euo pipefail

RELEASE_TAG="${TSA_RELEASE_TAG:-tsa-installer-v0.2.0-adhoc}"
BASE_URL="https://github.com/neivacadu/TSA-Installer/releases/download/${RELEASE_TAG}"
APP_NAME="${TSA_APP_NAME:-TSA.app}"
INSTALL_URL="https://neivacadu.github.io/TSA-Installer/install.sh"
REPAIR_CMD="curl -fsSL $INSTALL_URL | TSA_ONLY_PREREQS=1 bash"
BREW_INSTALLER_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
PY_FORMULA="python@3.14"
PG_FORMULA="postgresql@16"
# Ganchos do teste (scripts/test-install-prereqs.sh). Em uso normal ficam no padrao.
TTY_DEV="${TSA_TTY-/dev/tty}"
BREW_CANDIDATES="${TSA_BREW_CANDIDATES-/opt/homebrew/bin/brew /usr/local/bin/brew}"
PG_WAIT="${TSA_PG_WAIT:-30}"

TMP_DIR=""
MOUNT=""

say(){ printf '\033[0;36m%s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[0;33m!\033[0m %s\n' "$1"; }
die(){ printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

cleanup(){
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- app

install_app(){
  command -v curl >/dev/null || die "curl nao encontrado."

  local arch artifact expected actual src_app dest app_target
  arch="$(uname -m)"
  case "$arch" in
    arm64)  artifact="tsa-macos-arm64.dmg" ;;
    x86_64) artifact="tsa-macos-x64.dmg" ;;
    *) die "Arquitetura nao suportada: $arch" ;;
  esac

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tsa-install.XXXXXX")"

  say "Baixando o TSA ($arch)..."
  curl -fL --progress-bar "$BASE_URL/$artifact" -o "$TMP_DIR/$artifact" || die "Falha ao baixar $artifact"
  curl -fsSL "$BASE_URL/checksums-sha256.txt" -o "$TMP_DIR/checksums-sha256.txt" || die "Falha ao baixar os checksums"

  say "Conferindo integridade..."
  expected="$(awk -v n="$artifact" '$2==n{print $1}' "$TMP_DIR/checksums-sha256.txt")"
  [ -n "$expected" ] || die "Checksum ausente para $artifact"
  actual="$(shasum -a 256 "$TMP_DIR/$artifact" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "Checksum invalido (download corrompido). Tente de novo."
  ok "Download integro"

  say "Instalando..."
  MOUNT="$(hdiutil attach "$TMP_DIR/$artifact" -nobrowse -readonly </dev/null | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | head -1)"
  [ -n "$MOUNT" ] || die "Nao foi possivel montar o instalador."
  src_app="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$src_app" ] || die "Nenhum .app encontrado no pacote."

  dest="/Applications"
  [ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
  app_target="$dest/$APP_NAME"
  rm -rf "$app_target"
  ditto "$src_app" "$app_target" || die "Falha ao copiar o app."
  # ad-hoc: re-assina e remove a quarentena do Gatekeeper para abrir sem "app danificado"
  codesign --force --deep --sign - "$app_target" >/dev/null 2>&1 || true
  /usr/bin/xattr -dr com.apple.quarantine "$app_target" >/dev/null 2>&1 || true
  ok "$APP_NAME instalado em $dest"

  printf '\n\033[1;32mTSA instalado.\033[0m\n'
  printf 'Abra pelo Launchpad ou Aplicativos. Na primeira vez, se aparecer "editor desconhecido":\n'
  printf '  clique com o botao direito no app, Abrir, Abrir.\n'
  printf 'O DNA da TSA ja vem dentro e e aplicado no primeiro uso.\n\n'
}

# ---------------------------------------------------------------- preparacao do simulador

READY=""
PENDING=""
PENDING_N=0
BREW=""
BREW_FAILED=0
BREW_OFF_PATH=0

mark_ok(){ READY="${READY}  ✓ $1"$'\n'; }
mark_fail(){
  PENDING="${PENDING}  ✗ $1"$'\n'"      Para resolver: $2"$'\n'
  PENDING_N=$((PENDING_N + 1))
}

# Com curl | bash a entrada padrao e o script. Pergunta e sudo so leem do terminal.
has_tty(){ [ -n "$TTY_DEV" ] && { : <"$TTY_DEV"; } 2>/dev/null; }

brew_prefix(){ dirname "$(dirname "$BREW")"; }

# Acha o brew sem instalar. Se ele existe mas esta fora do PATH, carrega o shellenv.
find_brew(){
  [ -n "$BREW" ] && return 0
  local b
  b="$(command -v brew 2>/dev/null || true)"
  if [ -n "$b" ]; then BREW="$b"; return 0; fi
  for b in $BREW_CANDIDATES; do
    if [ -x "$b" ]; then
      BREW="$b"
      BREW_OFF_PATH=1
      eval "$("$BREW" shellenv </dev/null 2>/dev/null)" || true
      hash -r
      return 0
    fi
  done
  return 1
}

# Uma unica linha no .zprofile, e so quando o brew nao estava no PATH do usuario.
persist_brew_env(){
  [ "$BREW_OFF_PATH" = 1 ] || return 0
  local zp="$HOME/.zprofile"
  grep -qs 'brew shellenv' "$zp" && return 0
  printf '\neval "$(%s shellenv)"\n' "$BREW" >>"$zp" && ok "Homebrew adicionado ao PATH em $zp"
}

ensure_brew(){
  find_brew && return 0
  [ "$BREW_FAILED" = 1 ] && return 1
  BREW_FAILED=1
  if ! has_tty; then
    mark_fail "Homebrew: nao instalado, e sem terminal para pedir a senha do Mac." \
      "abra o app Terminal e rode: $REPAIR_CMD"
    return 1
  fi
  say "Instalando o Homebrew. O Mac pode pedir a sua senha."
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/brew-install.XXXXXX")"
  if curl -fsSL "$BREW_INSTALLER_URL" -o "$f"; then
    /bin/bash "$f" <"$TTY_DEV" || true
  fi
  rm -f "$f"
  if ! find_brew; then
    mark_fail "Homebrew: a instalacao nao terminou." \
      "/bin/bash -c \"\$(curl -fsSL $BREW_INSTALLER_URL)\""
    return 1
  fi
  BREW_FAILED=0
  BREW_OFF_PATH=1   # brew recem-instalado nunca esta no .zprofile
  persist_brew_env
  mark_ok "Homebrew: instalado"
}

# atalho: sem brew upgrade e sem atualizar dependentes; se uma dependencia desatualizada
# for exigida pela formula, o proprio brew install ainda pode atualiza-la.
brew_install(){
  say "Instalando $1..."
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ENV_HINTS=1 \
    "$BREW" install "$1" </dev/null
  local rc=$?
  hash -r
  persist_brew_env
  return $rc
}

PY_FOUND=""
find_python(){
  local n p
  for n in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10; do
    p="$(command -v "$n" 2>/dev/null)" || continue
    # sem as ferramentas de linha de comando, /usr/bin/python3 abre um aviso do macOS
    if [ "$p" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' </dev/null >/dev/null 2>&1; then
      PY_FOUND="$p"
      return 0
    fi
  done
  return 1
}

py_version(){ "$PY_FOUND" -c 'import platform; print(platform.python_version())' </dev/null 2>/dev/null; }

ensure_python(){
  if find_python; then
    mark_ok "Python $(py_version): ja estava pronto ($PY_FOUND)"
    return 0
  fi
  local fix="brew install $PY_FORMULA"
  if ! ensure_brew; then
    mark_fail "Python 3.10 ou mais: nao encontrado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if brew_install "$PY_FORMULA" && find_python; then
    mark_ok "Python $(py_version): instalado ($PY_FOUND)"
  else
    mark_fail "Python 3.10 ou mais: a instalacao falhou." "$fix"
  fi
}

ensure_node(){
  if command -v node >/dev/null 2>&1; then
    mark_ok "Node $(node --version </dev/null 2>/dev/null): ja estava pronto"
    return 0
  fi
  if ! ensure_brew; then
    mark_fail "Node: nao encontrado." "instale o Homebrew e rode: brew install node"
    return 1
  fi
  if brew_install node && command -v node >/dev/null 2>&1; then
    mark_ok "Node $(node --version </dev/null 2>/dev/null): instalado"
  else
    mark_fail "Node: a instalacao falhou." "brew install node"
  fi
}

pg_list_ok(){ PGCONNECT_TIMEOUT=5 psql -w -l </dev/null >/dev/null 2>&1; }

# Comando para ligar o servidor dono do psql que foi encontrado.
pg_start_hint(){
  local p f
  p="$(command -v psql)"
  p="$p $(readlink "$p" 2>/dev/null || true)"
  case "$p" in
    *Postgres.app*) echo "abra o app Postgres e clique em Start" ; return ;;
    *postgresql@*)  f="$(printf '%s' "$p" | sed 's#.*\(postgresql@[0-9]*\).*#\1#')" ;;
    *Cellar/postgresql/*|*opt/postgresql/*) f="postgresql" ;;
    *) echo "ligue o servico do PostgreSQL desta maquina (com Homebrew: brew services start $PG_FORMULA)"; return ;;
  esac
  echo "brew services start $f"
}

# postgresql@16 e keg-only: psql e createdb nao entram no bin do brew sozinhos.
# Escolha: brew link --force. Assim eles ficam no mesmo bin que o shellenv do brew ja
# coloca no PATH, sem outra linha no .zprofile. Se o link der conflito (outro psql
# ligado), cai para o PATH: sessao atual mais uma linha idempotente no .zprofile.
pg_make_reachable(){
  local pre kegbin
  pre="$(brew_prefix)"
  kegbin="$pre/opt/$PG_FORMULA/bin"
  if "$BREW" link --force "$PG_FORMULA" </dev/null >/dev/null 2>&1; then
    persist_brew_env
  else
    warn "brew link de $PG_FORMULA deu conflito; usando o PATH."
    grep -qsF "$kegbin" "$HOME/.zprofile" ||
      printf '\nexport PATH="%s:$PATH"\n' "$kegbin" >>"$HOME/.zprofile"
  fi
  case ":$PATH:" in *":$kegbin:"*) ;; *) export PATH="$kegbin:$PATH" ;; esac
  hash -r
}

ensure_postgres(){
  local keg_found=0 i
  if ! command -v psql >/dev/null 2>&1 && find_brew && [ -x "$(brew_prefix)/opt/$PG_FORMULA/bin/psql" ]; then
    # ja instalado antes, mas sem link: nao reinstala, so torna acessivel
    export PATH="$(brew_prefix)/opt/$PG_FORMULA/bin:$PATH"
    hash -r
    keg_found=1
  fi

  if command -v psql >/dev/null 2>&1; then
    [ "$keg_found" = 1 ] && pg_make_reachable
    if pg_list_ok; then
      mark_ok "PostgreSQL: ja estava ligado (psql -l responde)"
    elif command -v pg_isready >/dev/null 2>&1 && pg_isready -q </dev/null >/dev/null 2>&1; then
      mark_fail "PostgreSQL: o servidor responde, mas o usuario $(id -un) nao entra sem senha." \
        "veja o erro com: psql -d postgres -c 'select 1' e chame o suporte TSA"
    else
      mark_fail "PostgreSQL: o psql existe, mas o servidor nao responde." "$(pg_start_hint)"
    fi
    return 0
  fi

  local fix="brew install $PG_FORMULA && brew services start $PG_FORMULA"
  if ! ensure_brew; then
    mark_fail "PostgreSQL 16: nao encontrado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if ! brew_install "$PG_FORMULA"; then
    mark_fail "PostgreSQL 16: a instalacao falhou." "$fix"
    return 1
  fi
  pg_make_reachable
  say "Ligando o PostgreSQL 16..."
  if ! "$BREW" services start "$PG_FORMULA" </dev/null; then
    mark_fail "PostgreSQL 16: instalado, mas nao ligou." "brew services start $PG_FORMULA"
    return 1
  fi
  for ((i = 0; i < PG_WAIT; i++)); do
    pg_isready -q </dev/null >/dev/null 2>&1 && break
    sleep 1
  done
  if PGCONNECT_TIMEOUT=5 psql -w -d postgres -c 'select 1' </dev/null >/dev/null 2>&1; then
    mark_ok "PostgreSQL 16: instalado e ligado"
  else
    mark_fail "PostgreSQL 16: instalado, mas nao respondeu em ${PG_WAIT} s." \
      "brew services restart $PG_FORMULA"
  fi
}

prepare_simulator(){
  say "Preparando o Mac para o simulador ACE..."
  ensure_python || true
  ensure_node || true
  ensure_postgres || true

  printf '\n\033[1mSimulador ACE: requisitos do Mac\033[0m\n'
  printf '%s' "$READY$PENDING"
  if [ "$PENDING_N" = 0 ]; then
    printf '\nTudo pronto. O simulador ACE ja pode rodar pelo app.\n'
    return 0
  fi
  printf '\nFalta resolver %s item(ns). O simulador ACE so roda depois disso.\n' "$PENDING_N"
  [ "${TSA_ONLY_PREREQS:-0}" = 1 ] || printf 'O app TSA ja esta instalado e abre normalmente.\n'
  printf 'Depois de resolver, confira de novo com:\n  %s\n' "$REPAIR_CMD"
  return 1
}

main(){
  [ "$(uname -s)" = "Darwin" ] || die "Este instalador e para macOS. Para Windows, use o instalador do Windows."

  if [ "${TSA_ONLY_PREREQS:-0}" != 1 ]; then
    install_app
  fi

  if [ "${TSA_SKIP_PREREQS:-0}" = 1 ]; then
    say "Preparacao do simulador ACE pulada (TSA_SKIP_PREREQS=1)."
    return 0
  fi

  if prepare_simulator; then
    return 0
  fi
  # So o modo de teste manual devolve erro; a instalacao normal nunca cai por isso.
  [ "${TSA_ONLY_PREREQS:-0}" = 1 ] && return 1
  return 0
}

main "$@"
