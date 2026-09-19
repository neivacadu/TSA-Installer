#!/usr/bin/env bash
# Instalador do TSA (macOS) — comando unico, sem GitHub CLI e sem conta no GitHub.
#   curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | bash
# 1. Baixa o app do release publico, confere o SHA-256, instala e remove a quarentena.
#    O DNA da TSA ja vai embutido e assinado dentro do app.
# 2. Prepara o Mac para o simulador ACE, para a leitura de midia e para o ACE Audiovisual:
#    Python 3.10+, Node, PostgreSQL ligado, ffmpeg (com o filtro drawtext), pillow,
#    Antigravity CLI (agy), yt-dlp, whisper-cpp, o modelo de transcricao, o Handy e o
#    VoiceStudio. So instala o que falta, e so atualiza o yt-dlp velho.
#    Falha aqui nao desfaz o app. O login do agy e do colaborador, nunca do script.
# Controles:
#   TSA_SKIP_PREREQS=1  instala so o app, sem preparar o simulador.
#   TSA_ONLY_PREREQS=1  so prepara o simulador, sem baixar nem instalar o app.
#   TSA_BAIXAR_MODELO=1 autoriza baixar o modelo de 1,6 GB no modo de conferencia.
#   TSA_EDITOR_VIDEO=sim|nao responde a pergunta do editor de video (WhisperX e pycaps)
#                       e passa a ser a resposta guardada em ~/.config/tsa/editor-video.
# Tudo fica em funcoes e so roda na chamada de main na ultima linha. Com curl | bash,
# um download cortado no meio nao executa pela metade: sem a ultima linha, nada roda.
set -euo pipefail

RELEASE_TAG="${TSA_RELEASE_TAG:-tsa-installer-v0.4.5-adhoc}"
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
PG_PORT="${TSA_PG_PORT:-5432}"
POSTGRES_APP="${TSA_POSTGRES_APP:-/Applications/Postgres.app}"
SYS_PYTHON="${TSA_SYS_PYTHON:-/usr/bin/python3}"
AGY_URL="${TSA_AGY_URL:-https://antigravity.google/cli/install.sh}"
AGY_BIN_DIR="$HOME/.local/bin"           # destino do instalador oficial do agy
AGY_CREDS="$HOME/.gemini/oauth_creds.json"  # existe depois do login; nunca e lido
AGY_LOGIN="rode o comando agy, escolha Google OAuth e entre com o e-mail da empresa (@trafegosa.com.br ou @caduneiva.com)"
AGY_JANELA="deixe a janela do terminal grande, senao o campo do codigo fica escondido"
WHISPER_FORMULA="whisper-cpp"             # a formula e whisper-cpp; o comando e whisper-cli
WHISPER_DIR="${TSA_WHISPER_DIR:-$HOME/.cache/whisper}"
WHISPER_MODEL="ggml-large-v3-turbo.bin"
WHISPER_MODEL_URL="${TSA_WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL}"
WHISPER_MODEL_BYTES="${TSA_WHISPER_MODEL_BYTES:-1624555275}"   # 1,6 GB
MODELO_CMD="curl -fsSL $INSTALL_URL | TSA_ONLY_PREREQS=1 TSA_BAIXAR_MODELO=1 bash"
HANDY_APP="${TSA_HANDY_APP:-/Applications/Handy.app}"
HANDY_PERMISSOES="abra o Handy uma vez, conceda Microfone e Acessibilidade em Ajustes do Sistema e escolha o atalho de teclado"

# ---- ACE Audiovisual
# A formula ffmpeg do brew vem sem freetype desde a 9.x, e sem freetype nao existe o
# filtro drawtext, que escreve texto na tela. Quem traz o drawtext e a ffmpeg-full.
FFMPEG_FULL_FORMULA="ffmpeg-full"   # keg-only: nao entra no bin do brew sozinha
# A formula pillow poe o PIL no site-packages do Python do brew, nunca no do sistema.
PILLOW_FORMULA="pillow"
# VoiceStudio: clonagem de voz e dublagem local. App separado e AGPL, roda fora do TSA
# e nunca entra dentro dele. Existem repositorios falsos com o mesmo nome distribuindo
# binario com malware: so o endereco abaixo vale, e o DMG so entra depois do sha256.
VS_REPO="debpalash/VoiceStudio"
VS_TAG="${TSA_VS_TAG:-v0.5.3}"
VS_DMG="${TSA_VS_DMG:-VoiceStudio_0.5.3_aarch64.dmg}"
VS_SUMS="${TSA_VS_SUMS:-SHA256SUMS-macOS.Apple.Silicon.txt}"
VS_SHA256="${TSA_VS_SHA256:-8528ce1db299efa87db0072dc6a80152c3f4c753314194a02794215a564b1b84}"
VS_BASE_URL="${TSA_VS_BASE_URL:-https://github.com/$VS_REPO/releases/download/$VS_TAG}"
VS_APP="${TSA_VS_APP:-/Applications/VoiceStudio.app}"
VS_PRIMEIRO_USO="na primeira vez ele baixa um ambiente Python de cerca de 1,8 GB, o que leva de 5 a 10 minutos; isso acontece dentro do app, nao aqui no instalador"
VS_GATEKEEPER="ele e assinado ad-hoc, sem Team ID da Apple; se o macOS recusar abrir, clique com o botao direito no app, Abrir, Abrir"
VS_MANUAL="baixe $VS_DMG so em https://github.com/$VS_REPO/releases e confira o sha256 com o arquivo $VS_SUMS da mesma release"

# ---- WhisperX e pycaps: so para quem edita video (decisao do Cadu, 19/09/2026)
# Juntos passam de 3 GB e levam uns 25 minutos (o PyTorch do WhisperX). Quem instala e o
# tsa_editor.py do app, fonte unica das versoes fixadas; aqui so se decide se roda.
EDITOR_VIDEO_FILE="$HOME/.config/tsa/editor-video"
EDITOR_VIDEO_PY="${TSA_EDITOR_PY:-}"   # gancho do teste; vazio = procura dentro do app
EDITOR_VIDEO_REL="Contents/Resources/tsa/corte/tsa_editor.py"
# Onde o brew guarda o python@3.X (keg). Gancho do teste; em uso normal fica no padrao.
EDITOR_VIDEO_PY_ROOTS="${TSA_EDITOR_PY_ROOTS-/opt/homebrew/opt /usr/local/opt}"
EDITOR_VIDEO_PERGUNTA="Você edita vídeo (Premiere Pro ou CapCut)? [s/N] "
EDITOR_VIDEO_MUDAR="curl -fsSL $INSTALL_URL | TSA_ONLY_PREREQS=1 TSA_EDITOR_VIDEO=sim bash"
EDITOR_VIDEO=""
APP_INSTALADO=""   # preenchido pelo install_app
AGY_PENDENTE=""    # login do agy faltando

TMP_DIR=""
MOUNT=""
VS_TMP=""
VS_MOUNT=""

say(){ printf '\033[0;36m%s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[0;33m!\033[0m %s\n' "$1"; }
die(){ printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

cleanup(){
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  if [ -n "$VS_MOUNT" ]; then hdiutil detach "$VS_MOUNT" >/dev/null 2>&1 || true; fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
  if [ -n "$VS_TMP" ]; then rm -rf "$VS_TMP"; fi
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
  APP_INSTALADO="$app_target"
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
AVISOS=""
PENDING_N=0
BREW=""
BREW_FAILED=0
BREW_OFF_PATH=0
BREW_PREFIX=""

mark_ok(){ READY="${READY}  ✓ $1"$'\n'; }
# $3 e uma observacao opcional, numa linha extra.
mark_fail(){
  PENDING="${PENDING}  ✗ $1"$'\n'"      Para resolver: $2"$'\n'
  [ -n "${3:-}" ] && PENDING="${PENDING}      Atencao: $3"$'\n'
  PENDING_N=$((PENDING_N + 1))
}
# Aviso entra no resumo e nao conta como pendencia: nao prende o simulador nem o app.
mark_aviso(){
  AVISOS="${AVISOS}  ! $1"$'\n'
  [ -n "${2:-}" ] && AVISOS="${AVISOS}      Para resolver: $2"$'\n'
  return 0
}

# Com curl | bash a entrada padrao e o script. Pergunta e sudo so leem do terminal.
has_tty(){ [ -n "$TTY_DEV" ] && { : <"$TTY_DEV"; } 2>/dev/null; }

# Preenche BREW_PREFIX uma vez. Chamar fora de $(...), senao o valor se perde no subshell.
load_brew_prefix(){
  [ -n "$BREW_PREFIX" ] && return 0
  BREW_PREFIX="$("$BREW" --prefix </dev/null 2>/dev/null || true)"
  [ -n "$BREW_PREFIX" ] || BREW_PREFIX="$(dirname "$(dirname "$BREW")")"
}

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
# O nome vem por ultimo, entao "brew_install --cask handy" tambem funciona.
brew_install(){
  say "Instalando ${*: -1}..."
  HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ENV_HINTS=1 \
    "$BREW" install "$@" </dev/null
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
    if [ "$p" = "$SYS_PYTHON" ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
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

ensure_ffmpeg(){
  if command -v ffmpeg >/dev/null 2>&1; then
    mark_ok "ffmpeg: ja estava pronto"
    return 0
  fi
  if ! ensure_brew; then
    mark_fail "ffmpeg: nao encontrado." "instale o Homebrew e rode: brew install ffmpeg"
    return 1
  fi
  if brew_install ffmpeg && command -v ffmpeg >/dev/null 2>&1; then
    mark_ok "ffmpeg: instalado"
  else
    mark_fail "ffmpeg: a instalacao falhou." "brew install ffmpeg"
  fi
}

ffmpeg_tem_drawtext(){ ffmpeg -hide_banner -filters </dev/null 2>/dev/null | grep -qw drawtext; }

# drawtext e o filtro que escreve texto na tela, e ele so existe quando o ffmpeg foi
# compilado com freetype. A formula ffmpeg do brew nao traz freetype: quem traz e a
# ffmpeg-full, que e keg-only e nao entra no bin do brew sozinha. Por isso o bin dela
# vai para a frente do PATH, igual ao postgresql@16. Faltar drawtext e aviso, nao
# pendencia: o pillow cobre o caso gerando o texto como imagem.
ensure_drawtext(){
  if ffmpeg_tem_drawtext; then
    mark_ok "ffmpeg com o filtro drawtext: ja estava pronto"
    return 0
  fi
  local fix="brew install $FFMPEG_FULL_FORMULA"
  local falta="ffmpeg sem o filtro drawtext: nao da para escrever texto na tela pelo ffmpeg; o texto sai como imagem pelo pillow."
  if ! ensure_brew; then
    mark_aviso "$falta" "instale o Homebrew e rode: $fix"
    return 1
  fi
  load_brew_prefix
  local kegbin="$BREW_PREFIX/opt/$FFMPEG_FULL_FORMULA/bin"
  # ja instalada antes, so fora do PATH: nao reinstala
  if [ ! -x "$kegbin/ffmpeg" ]; then
    brew_install "$FFMPEG_FULL_FORMULA" || true
  fi
  if [ -x "$kegbin/ffmpeg" ]; then
    path_persistente "$kegbin"
  fi
  if ffmpeg_tem_drawtext; then
    mark_ok "ffmpeg com o filtro drawtext: instalado pela formula $FFMPEG_FULL_FORMULA ($kegbin)"
  else
    mark_aviso "$falta" "$fix"
  fi
}

# Onde o pillow esta importavel: no Python que o script achou ou no Python do brew.
PIL_PY=""
find_pillow(){
  local p prefix="$BREW_PREFIX"
  PIL_PY=""
  # so olha, nunca chama o brew: uma conferencia nao pode mexer na maquina
  if [ -z "$prefix" ] && [ -n "$BREW" ]; then prefix="$(dirname "$(dirname "$BREW")")"; fi
  for p in "$PY_FOUND" "$prefix/opt/$PY_FORMULA/libexec/bin/python"; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" -c 'import PIL' </dev/null >/dev/null 2>&1; then
      PIL_PY="$p"
      return 0
    fi
  done
  return 1
}

# Escreve o texto como imagem quando o ffmpeg nao tem drawtext. A formula pillow do brew
# instala no site-packages do Python do brew, entao o Python do sistema fica intocado.
ensure_pillow(){
  if find_pillow; then
    mark_ok "pillow (texto como imagem): ja estava pronto ($PIL_PY)"
    return 0
  fi
  local fix="brew install $PILLOW_FORMULA"
  if ! ensure_brew; then
    mark_fail "pillow (texto como imagem): nao encontrado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if brew_install "$PILLOW_FORMULA" && find_pillow; then
    mark_ok "pillow (texto como imagem): instalado ($PIL_PY)"
  else
    mark_fail "pillow (texto como imagem): a instalacao falhou." "$fix"
  fi
}

# VoiceStudio: app separado, ferramenta da pessoa igual ao Handy, entao faltar e aviso e
# nunca pendencia. Nada e instalado sem o sha256 bater duas vezes: primeiro o sha256 que
# a release publica, depois o sha256 do arquivo que chegou. Qualquer diferenca recusa.
ensure_voicestudio(){
  if [ -d "$VS_APP" ]; then
    mark_ok "VoiceStudio (clonagem de voz e dublagem): ja estava pronto"
    mark_aviso "VoiceStudio: $VS_PRIMEIRO_USO"
    return 0
  fi
  local dest publicado atual src sums dmg
  dest="$(dirname "$VS_APP")"
  if [ ! -d "$dest" ] || [ ! -w "$dest" ]; then
    mark_aviso "VoiceStudio: nao da para escrever em $dest." "$VS_MANUAL"
    return 1
  fi
  if [ "$(uname -m)" != "arm64" ]; then
    mark_aviso "VoiceStudio: so o pacote Apple Silicon foi conferido pela TSA." "$VS_MANUAL"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    mark_aviso "VoiceStudio: nao instalado e sem curl para baixar." "$VS_MANUAL"
    return 1
  fi
  VS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsa-voicestudio.XXXXXX")" || true
  if [ -z "$VS_TMP" ]; then
    mark_aviso "VoiceStudio: nao deu para criar a pasta temporaria." "$VS_MANUAL"
    return 1
  fi
  sums="$VS_TMP/$VS_SUMS"
  dmg="$VS_TMP/$VS_DMG"

  say "Conferindo o sha256 que a release $VS_TAG do VoiceStudio publica..."
  if ! curl -fsSL --max-time 60 "$VS_BASE_URL/$VS_SUMS" -o "$sums" </dev/null; then
    mark_aviso "VoiceStudio: $VS_SUMS da release $VS_TAG nao baixou." "$VS_MANUAL"
    return 1
  fi
  publicado="$(awk -v n="$VS_DMG" '$2==n{print $1}' "$sums" 2>/dev/null | head -1 || true)"
  if [ "$publicado" != "$VS_SHA256" ]; then
    mark_aviso "VoiceStudio: o sha256 de $VS_DMG na release (${publicado:-ausente}) nao e o que a TSA conferiu; nao baixei o DMG." \
      "existe copia falsa deste projeto com malware: avise o suporte TSA antes de instalar por fora"
    return 1
  fi
  say "Baixando o VoiceStudio $VS_TAG (102 MB)..."
  if ! curl -fL --progress-bar --max-time 900 "$VS_BASE_URL/$VS_DMG" -o "$dmg" </dev/null; then
    mark_aviso "VoiceStudio: o download de $VS_DMG nao terminou." "$VS_MANUAL"
    return 1
  fi
  atual="$(shasum -a 256 "$dmg" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$atual" != "$VS_SHA256" ]; then
    rm -f "$dmg"
    mark_aviso "VoiceStudio: o sha256 do arquivo baixado (${atual:-nao calculado}) nao bateu; apaguei o DMG e nao instalei." \
      "existe copia falsa deste projeto com malware: avise o suporte TSA antes de instalar por fora"
    return 1
  fi
  ok "VoiceStudio: sha256 conferido na release e no arquivo"

  say "Instalando o VoiceStudio..."
  # O hdiutil lista uma linha por particao, com os campos separados por tabulacao. O
  # ponto de montagem e o ultimo campo da ultima linha que tem caminho.
  VS_MOUNT="$(hdiutil attach "$dmg" -nobrowse -readonly </dev/null 2>/dev/null | awk -F'\t' '$NF ~ "^/" {m=$NF} END{print m}' || true)"
  if [ -z "$VS_MOUNT" ]; then
    mark_aviso "VoiceStudio: nao foi possivel montar $VS_DMG." "$VS_MANUAL"
    return 1
  fi
  src="$(find "$VS_MOUNT" -maxdepth 1 -name '*.app' 2>/dev/null | head -1 || true)"
  if [ -z "$src" ]; then
    mark_aviso "VoiceStudio: nenhum .app dentro de $VS_DMG." "$VS_MANUAL"
    return 1
  fi
  rm -rf "$VS_APP"
  if ! ditto "$src" "$VS_APP"; then
    mark_aviso "VoiceStudio: a copia para $VS_APP falhou." "$VS_MANUAL"
    return 1
  fi
  hdiutil detach "$VS_MOUNT" >/dev/null 2>&1 || true
  VS_MOUNT=""
  xattr -dr com.apple.quarantine "$VS_APP" >/dev/null 2>&1 || true
  mark_ok "VoiceStudio (clonagem de voz e dublagem): instalado em $VS_APP"
  mark_aviso "VoiceStudio: $VS_PRIMEIRO_USO"
  mark_aviso "VoiceStudio: $VS_GATEKEEPER"
}

# O instalador oficial poe o binario em ~/.local/bin, que nem sempre esta no PATH.
find_agy(){
  command -v agy >/dev/null 2>&1 && return 0
  if [ -x "$AGY_BIN_DIR/agy" ]; then
    path_persistente "$AGY_BIN_DIR"
    return 0
  fi
  return 1
}

agy_logado(){ [ -s "$AGY_CREDS" ]; }

agy_resumo(){ # 1 = como foi parar aqui (ja estava pronto / instalado)
  local v
  v="$(agy --version </dev/null 2>/dev/null | head -1 || true)"
  if agy_logado; then
    mark_ok "Antigravity agy ${v:-sem versao}: $1, com login feito"
  else
    AGY_PENDENTE=1
    mark_fail "Antigravity agy ${v:-sem versao}: $1, mas sem login." "$AGY_LOGIN" "$AGY_JANELA"
  fi
}

ensure_agy(){
  if find_agy; then
    agy_resumo "ja estava pronto"
    return 0
  fi
  local fix="curl -fsSL $AGY_URL | bash"
  if ! command -v curl >/dev/null 2>&1; then
    mark_fail "Antigravity (agy): nao encontrado e sem curl para baixar." "$fix"
    return 1
  fi
  # confere o endereco antes de baixar: nada de instalar as cegas
  if ! curl -fsSI --max-time 20 "$AGY_URL" </dev/null >/dev/null 2>&1; then
    mark_fail "Antigravity (agy): $AGY_URL nao respondeu 200." "confira a internet e rode depois: $fix"
    return 1
  fi
  say "Instalando o Antigravity CLI (agy)..."
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/agy-install.XXXXXX")"
  if curl -fsSL --max-time 120 "$AGY_URL" -o "$f"; then
    /bin/bash "$f" </dev/null || true
  fi
  rm -f "$f"
  hash -r
  if find_agy; then
    agy_resumo "instalado"
  else
    mark_fail "Antigravity (agy): a instalacao nao terminou." "$fix"
  fi
}

ytdlp_versao(){ yt-dlp --version </dev/null 2>/dev/null | head -1; }

# So o yt-dlp envelhece sozinho: quando o YouTube muda, a versao velha da HTTP 403.
# Por isso ele e o unico que o script atualiza. "brew outdated" sai 0 mesmo quando esta
# em dia, entao o que vale e a saida ter texto.
ytdlp_atualiza(){
  local v
  v="$(ytdlp_versao)"
  if [ -z "$BREW" ] || [ -z "$("$BREW" outdated yt-dlp </dev/null 2>/dev/null)" ]; then
    mark_ok "yt-dlp ${v:-sem versao}: ja estava pronto"
    return 0
  fi
  say "Atualizando o yt-dlp (a versao velha da erro 403 no YouTube)..."
  if HOMEBREW_NO_ENV_HINTS=1 "$BREW" upgrade yt-dlp </dev/null; then
    hash -r
    mark_ok "yt-dlp $(ytdlp_versao): atualizado (a versao anterior era $v)"
  else
    mark_aviso "yt-dlp $v: esta velho e a atualizacao falhou; o YouTube pode dar erro 403." \
      "brew upgrade yt-dlp"
  fi
}

# Higgsfield CLI oficial (MIT): geracao de imagem e video da Fabrica e do ACE Audiovisual.
# Vem do npm. O login fica com cada pessoa: higgsfield auth login.
ensure_higgsfield(){
  if command -v higgsfield >/dev/null 2>&1; then
    mark_ok "Higgsfield CLI $(higgsfield --version 2>/dev/null | awk '{print $2}'): ja estava pronto"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    mark_aviso "Higgsfield CLI: npm nao encontrado; a geracao de video pelo Higgsfield fica indisponivel." "brew install node && npm install -g @higgsfield/cli"
    return 0
  fi
  if npm install -g @higgsfield/cli >/dev/null 2>&1 && command -v higgsfield >/dev/null 2>&1; then
    mark_ok "Higgsfield CLI $(higgsfield --version 2>/dev/null | awk '{print $2}'): instalado (entre com: higgsfield auth login)"
  else
    mark_aviso "Higgsfield CLI: a instalacao falhou; a geracao de video pelo Higgsfield fica indisponivel." "npm install -g @higgsfield/cli"
  fi
}

# Ferramentas leves do ACE Audiovisual (DEC-AV-03). Versao fixada; falha e aviso, nunca
# pendencia. As outras quatro (premiere-mcp, whisperx, pycaps, openshorts) sao sob pedido,
# pelo tsa-editor --instalar do app.
AUTOEDITOR_VERSAO="31.6.0"
CAPCUT_VERSAO="0.25.0"
versao_de(){ "$1" --version </dev/null 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }

# auto-editor (Unlicense): corte de silencio e sequencia para Premiere, Resolve e Final Cut.
# O brew nao fixa versao: instala a stable, e versao diferente ja instalada vira aviso.
ensure_autoeditor(){
  local v
  if command -v auto-editor >/dev/null 2>&1; then
    v="$(versao_de auto-editor)"
    if [ "$v" = "$AUTOEDITOR_VERSAO" ]; then
      mark_ok "auto-editor $v: ja estava pronto"
    else
      mark_aviso "auto-editor ${v:-sem versao}: a versao conferida pela TSA e a $AUTOEDITOR_VERSAO." "brew upgrade auto-editor"
    fi
    return 0
  fi
  if ! ensure_brew; then
    mark_aviso "auto-editor: nao instalado; o corte de silencio para o editor fica indisponivel." "instale o Homebrew e rode: brew install auto-editor"
    return 0
  fi
  if brew_install auto-editor && command -v auto-editor >/dev/null 2>&1; then
    mark_ok "auto-editor $(versao_de auto-editor): instalado"
  else
    mark_aviso "auto-editor: a instalacao falhou; o corte de silencio para o editor fica indisponivel." "brew install auto-editor"
  fi
  return 0
}

# capcut-cli (MIT): projeto do CapCut com legenda karaoke. Vem do npm, na versao fixada.
ensure_capcut(){
  local v=""
  command -v capcut-cli >/dev/null 2>&1 && v="$(versao_de capcut-cli)"
  if [ "$v" = "$CAPCUT_VERSAO" ]; then
    mark_ok "capcut-cli $v: ja estava pronto"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    mark_aviso "capcut-cli: npm nao encontrado; o projeto do CapCut pelo agente fica indisponivel." "brew install node && npm install -g capcut-cli@$CAPCUT_VERSAO"
    return 0
  fi
  if npm install -g "capcut-cli@$CAPCUT_VERSAO" >/dev/null 2>&1 && [ "$(versao_de capcut-cli)" = "$CAPCUT_VERSAO" ]; then
    mark_ok "capcut-cli $CAPCUT_VERSAO: instalado${v:+ (a versao anterior era $v)}"
  else
    mark_aviso "capcut-cli: a instalacao falhou; o projeto do CapCut pelo agente fica indisponivel." "npm install -g capcut-cli@$CAPCUT_VERSAO"
  fi
  return 0
}

# Decide uma vez, no comeco da preparacao, para a pessoa nao ter de esperar a pergunta.
# Ordem: TSA_EDITOR_VIDEO, resposta guardada, pergunta no terminal. Sem terminal = nao,
# e essa resposta padrao nao e guardada: a proxima execucao com terminal pergunta.
decidir_editor_video(){
  local r=""
  case "${TSA_EDITOR_VIDEO:-}" in
    sim|nao) EDITOR_VIDEO="$TSA_EDITOR_VIDEO"; guardar_editor_video; return 0 ;;
    "") ;;
    *) warn "TSA_EDITOR_VIDEO=$TSA_EDITOR_VIDEO ignorado: use sim ou nao." ;;
  esac
  [ -f "$EDITOR_VIDEO_FILE" ] && r="$(head -1 "$EDITOR_VIDEO_FILE" 2>/dev/null || true)"
  case "$r" in sim|nao) EDITOR_VIDEO="$r"; return 0 ;; esac
  EDITOR_VIDEO="nao"
  has_tty || return 0
  printf '\nQuem edita video recebe o WhisperX e o pycaps: cerca de 3 GB e 25 minutos a mais.\n'
  printf '%s' "$EDITOR_VIDEO_PERGUNTA"
  read -r r <"$TTY_DEV" || r=""
  case "$r" in [sS]|[sS][iI][mM]|[yY]|[yY][eE][sS]) EDITOR_VIDEO="sim" ;; esac
  guardar_editor_video
}
guardar_editor_video(){
  { mkdir -p "$(dirname "$EDITOR_VIDEO_FILE")" && printf '%s\n' "$EDITOR_VIDEO" >"$EDITOR_VIDEO_FILE"; } 2>/dev/null || true
}

# Procura o tsa_editor.py no app que acabou de ser instalado ou num ja instalado antes.
editor_video_py(){
  local c
  if [ -n "$EDITOR_VIDEO_PY" ]; then [ -f "$EDITOR_VIDEO_PY" ] && printf '%s' "$EDITOR_VIDEO_PY"; return; fi
  for c in "${APP_INSTALADO:+$APP_INSTALADO/$EDITOR_VIDEO_REL}" \
           "/Applications/$APP_NAME/$EDITOR_VIDEO_REL" "$HOME/Applications/$APP_NAME/$EDITOR_VIDEO_REL"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Algum Python de 3.10 a 3.12 que o tsa_editor aceita (mesmos lugares onde ele procura).
editor_video_tem_python(){
  local m c r
  for m in 12 11 10; do
    c="$(command -v "python3.$m" 2>/dev/null || true)"
    [ -n "$c" ] && [ -x "$c" ] && return 0
    for r in $EDITOR_VIDEO_PY_ROOTS; do
      [ -x "$r/python@3.$m/bin/python3.$m" ] && return 0
    done
  done
  return 1
}

# Roda depois do app instalado. Ja instalado na versao certa, o tsa_editor so confere.
# Codigo 1 = falta requisito; 2 = falhou. Os dois sao aviso, nunca pendencia.
ensure_editor_video(){
  if [ "$EDITOR_VIDEO" != sim ]; then
    mark_ok "WhisperX e pycaps: fora, pela resposta de que nao edita video. Para mudar: $EDITOR_VIDEO_MUDAR"
    return 0
  fi
  local py id rc
  if ! py="$(editor_video_py)"; then
    mark_aviso "WhisperX e pycaps: nao achei o tsa_editor.py dentro do $APP_NAME." \
      "instale o app e rode: tsa-editor --instalar whisperx && tsa-editor --instalar pycaps"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    mark_aviso "WhisperX e pycaps: sem python3 para rodar o tsa_editor." "tsa-editor --instalar whisperx && tsa-editor --instalar pycaps"
    return 0
  fi
  # O WhisperX aceita Python 3.10 a 3.13 e o pycaps 3.10 a 3.12; o Homebrew de hoje traz o 3.14.
  # Sem um 3.10-3.12 na maquina, instala o python@3.12, que o tsa_editor acha em /opt/homebrew/opt.
  if ! editor_video_tem_python; then
    say "Instalando o Python 3.12, que o WhisperX e o pycaps pedem (o Python 3.14 do Mac nao serve para eles)."
    # O resultado decide: o brew pode sair com erro so no passo de link e o keg ficar pronto.
    ensure_brew && { brew_install python@3.12 || true; }
    if ! editor_video_tem_python; then
      mark_aviso "WhisperX e pycaps: nao consegui instalar o Python 3.12." \
        "brew install python@3.12 && tsa-editor --instalar whisperx && tsa-editor --instalar pycaps"
      return 0
    fi
  fi
  say "Instalando o WhisperX e o pycaps para edicao de video. Pode levar uns 25 minutos e ocupar uns 3 GB."
  for id in whisperx pycaps; do
    rc=0
    python3 "$py" --instalar "$id" </dev/null || rc=$?
    case "$rc" in
      0) mark_ok "$id: pronto para edicao de video" ;;
      1) mark_aviso "$id: nao instalado, falta um requisito (o motivo saiu logo acima)." "tsa-editor --instalar $id" ;;
      *) mark_aviso "$id: a instalacao falhou (codigo $rc)." "tsa-editor --instalar $id" ;;
    esac
  done
  return 0
}

ensure_ytdlp(){
  if command -v yt-dlp >/dev/null 2>&1; then
    find_brew || true
    ytdlp_atualiza
    return 0
  fi
  if ! ensure_brew; then
    mark_fail "yt-dlp: nao encontrado." "instale o Homebrew e rode: brew install yt-dlp"
    return 1
  fi
  if brew_install yt-dlp && command -v yt-dlp >/dev/null 2>&1; then
    mark_ok "yt-dlp $(ytdlp_versao): instalado"
  else
    mark_fail "yt-dlp: a instalacao falhou." "brew install yt-dlp"
  fi
}

# A formula e whisper-cpp, mas quem transcreve e o comando whisper-cli. Confere o comando.
ensure_whisper(){
  if command -v whisper-cli >/dev/null 2>&1; then
    mark_ok "whisper-cli: ja estava pronto"
    return 0
  fi
  local fix="brew install $WHISPER_FORMULA"
  if ! ensure_brew; then
    mark_fail "whisper-cli: nao encontrado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if brew_install "$WHISPER_FORMULA" && command -v whisper-cli >/dev/null 2>&1; then
    mark_ok "whisper-cli: instalado"
  else
    mark_fail "whisper-cli: a instalacao falhou." "$fix"
  fi
}

modelo_bytes(){ /usr/bin/stat -f %z "$1" 2>/dev/null || echo 0; }

# Baixa para .parcial e so renomeia quando o tamanho bate. Retoma download interrompido.
baixar_modelo(){
  local destino="$1" parcial="$1.parcial" tam
  mkdir -p "$WHISPER_DIR" || return 1
  say "Modelo de transcricao $WHISPER_MODEL: 1,6 GB ($WHISPER_MODEL_BYTES bytes) para baixar."
  say "Leva uns 3 min a 10 MB/s e uns 14 min a 2 MB/s. Pode interromper: o download retoma."
  curl -fL --progress-bar --continue-at - "$WHISPER_MODEL_URL" -o "$parcial" </dev/null || return 1
  tam="$(modelo_bytes "$parcial")"
  if [ "$tam" != "$WHISPER_MODEL_BYTES" ]; then
    warn "Download incompleto: $tam de $WHISPER_MODEL_BYTES bytes. O pedaco ficou em $parcial."
    return 1
  fi
  mv "$parcial" "$destino"
}

ensure_whisper_model(){
  local destino="$WHISPER_DIR/$WHISPER_MODEL" tam
  if [ -f "$destino" ]; then
    tam="$(modelo_bytes "$destino")"
    if [ "$tam" = "$WHISPER_MODEL_BYTES" ]; then
      mark_ok "Modelo $WHISPER_MODEL: ja estava pronto ($WHISPER_DIR)"
      return 0
    fi
    warn "O modelo em $destino tem $tam bytes e o certo sao $WHISPER_MODEL_BYTES. Vou baixar de novo."
    rm -f "$destino"
  fi
  # O unico item pesado. Na conferencia, avisa e da o comando; nunca segura a maquina.
  if [ "${TSA_ONLY_PREREQS:-0}" = 1 ] && [ "${TSA_BAIXAR_MODELO:-0}" != 1 ]; then
    mark_fail "Modelo $WHISPER_MODEL: falta em $WHISPER_DIR e sao 1,6 GB." \
      "com tempo e internet boa, rode: $MODELO_CMD"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    mark_fail "Modelo $WHISPER_MODEL: falta em $WHISPER_DIR e nao ha curl para baixar." "$MODELO_CMD"
    return 1
  fi
  if baixar_modelo "$destino"; then
    mark_ok "Modelo $WHISPER_MODEL: baixado ($WHISPER_DIR)"
  else
    mark_fail "Modelo $WHISPER_MODEL: o download nao terminou." \
      "rode de novo, que ele retoma de onde parou: $MODELO_CMD"
  fi
}

# Ditado por microfone, ferramenta da pessoa. Nao faz parte da esteira de video, entao
# falta de Handy e aviso, nunca pendencia. Permissao so a pessoa concede.
ensure_handy(){
  if [ -d "$HANDY_APP" ]; then
    mark_ok "Handy (ditado por microfone): ja estava pronto"
    mark_aviso "Handy: $HANDY_PERMISSOES"
    return 0
  fi
  local fix="brew install --cask handy"
  if ! ensure_brew; then
    mark_aviso "Handy (ditado por microfone): nao instalado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if brew_install --cask handy && [ -d "$HANDY_APP" ]; then
    mark_ok "Handy (ditado por microfone): instalado"
    mark_aviso "Handy: $HANDY_PERMISSOES"
  else
    mark_aviso "Handy (ditado por microfone): a instalacao falhou." "$fix"
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

# Poe um bin no PATH: na sessao atual e numa linha idempotente do .zprofile.
path_persistente(){
  local bin="$1"
  grep -qsF "$bin" "$HOME/.zprofile" ||
    printf '\nexport PATH="%s:$PATH"\n' "$bin" >>"$HOME/.zprofile"
  case ":$PATH:" in *":$bin:"*) ;; *) export PATH="$bin:$PATH" ;; esac
  hash -r
}

# So para o postgresql@16 instalado agora. Ele e keg-only: psql e createdb nao entram
# no bin do brew sozinhos. Escolha: brew link --force, que poe os dois no bin que o
# shellenv do brew ja coloca no PATH, sem outra linha no .zprofile. Se o link der
# conflito (outro psql ligado), cai para o PATH.
pg_link_new_install(){
  load_brew_prefix
  local kegbin="$BREW_PREFIX/opt/$PG_FORMULA/bin"
  if "$BREW" link --force "$PG_FORMULA" </dev/null >/dev/null 2>&1; then
    persist_brew_env
    case ":$PATH:" in *":$kegbin:"*) ;; *) export PATH="$kegbin:$PATH" ;; esac
    hash -r
  else
    warn "brew link de $PG_FORMULA deu conflito; usando o PATH."
    path_persistente "$kegbin"
  fi
}

# Algum servidor na porta? Diz o bin do psql dele quando consegue achar.
PG_PORT_BIN=""
pg_port_busy(){
  local pid bin
  PG_PORT_BIN=""
  pid="$(/usr/sbin/lsof -nP -t -iTCP:"$PG_PORT" -sTCP:LISTEN 2>/dev/null </dev/null | head -1)"
  if [ -n "$pid" ]; then
    bin="$(/bin/ps -o comm= -p "$pid" 2>/dev/null | head -1)"
    case "$bin" in
      /*) bin="$(dirname "$bin")"; [ -x "$bin/psql" ] && PG_PORT_BIN="$bin" ;;
    esac
    return 0
  fi
  /usr/bin/nc -z 127.0.0.1 "$PG_PORT" </dev/null >/dev/null 2>&1
}

# Antes de instalar: existe outro PostgreSQL nesta maquina? Se existe, nao instala.
pg_found_elsewhere(){
  local k fix
  if [ -n "$BREW" ]; then
    load_brew_prefix
    for k in "$BREW_PREFIX"/opt/postgresql*/bin/psql; do
      [ -x "$k" ] || continue
      k="$(dirname "$k")"
      mark_fail "PostgreSQL: ja existe um PostgreSQL do Homebrew fora do PATH ($k)." \
        "echo 'export PATH=\"$k:\$PATH\"' >> ~/.zprofile, abra um Terminal novo e ligue com: brew services start $(basename "$(dirname "$k")")"
      return 0
    done
  fi
  if [ -d "$POSTGRES_APP" ]; then
    k="$POSTGRES_APP/Contents/Versions/latest/bin"
    mark_fail "PostgreSQL: o app Postgres ja esta instalado ($POSTGRES_APP), mas o psql nao esta no PATH." \
      "abra o app Postgres, ligue o servidor e rode: echo 'export PATH=\"$k:\$PATH\"' >> ~/.zprofile"
    return 0
  fi
  if pg_port_busy; then
    if [ -n "$PG_PORT_BIN" ]; then
      fix="echo 'export PATH=\"$PG_PORT_BIN:\$PATH\"' >> ~/.zprofile e abra um Terminal novo"
    else
      fix="descubra qual programa usa a porta com: lsof -nP -iTCP:$PG_PORT -sTCP:LISTEN e ponha o psql dele no PATH"
    fi
    mark_fail "PostgreSQL: a porta $PG_PORT ja esta em uso, mas o psql nao esta no PATH." "$fix"
    return 0
  fi
  return 1
}

ensure_postgres(){
  local kegbin="" i ver
  if ! command -v psql >/dev/null 2>&1 && [ -n "$BREW" ]; then
    load_brew_prefix
    kegbin="$BREW_PREFIX/opt/$PG_FORMULA/bin"
    if [ -x "$kegbin/psql" ]; then
      # ja instalado antes, sem link: nao reinstala nem linka, so usa o PATH
      path_persistente "$kegbin"
    fi
  fi

  if command -v psql >/dev/null 2>&1; then
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

  pg_found_elsewhere && return 0

  local fix="brew install $PG_FORMULA && brew services start $PG_FORMULA"
  if ! ensure_brew; then
    mark_fail "PostgreSQL 16: nao encontrado." "instale o Homebrew e rode: $fix"
    return 1
  fi
  if ! brew_install "$PG_FORMULA"; then
    mark_fail "PostgreSQL 16: a instalacao falhou." "$fix"
    return 1
  fi
  pg_link_new_install
  say "Ligando o PostgreSQL 16..."
  if ! "$BREW" services start "$PG_FORMULA" </dev/null; then
    mark_fail "PostgreSQL 16: instalado, mas nao ligou." "brew services start $PG_FORMULA"
    return 1
  fi
  for ((i = 0; i < PG_WAIT; i++)); do
    pg_isready -q </dev/null >/dev/null 2>&1 && break
    sleep 1
  done
  if ! PGCONNECT_TIMEOUT=5 psql -w -d postgres -c 'select 1' </dev/null >/dev/null 2>&1; then
    mark_fail "PostgreSQL 16: instalado, mas nao respondeu em ${PG_WAIT} s." \
      "brew services restart $PG_FORMULA"
    return 1
  fi
  # Confere que quem respondeu e o 16 instalado agora, e nao outro servidor.
  ver="$(PGCONNECT_TIMEOUT=5 psql -w -d postgres -tAc 'show server_version_num' </dev/null 2>/dev/null || true)"
  case "$ver" in
    16*) mark_ok "PostgreSQL 16: instalado e ligado" ;;
    *) mark_fail "PostgreSQL 16: instalado, mas quem respondeu foi outro servidor (versao ${ver:-desconhecida})." \
         "confira com: psql -d postgres -c 'show server_version' e desligue o servidor antigo" ;;
  esac
}

prepare_simulator(){
  say "Preparando o Mac para o simulador ACE..."
  # brew fora do PATH (segunda execucao na mesma janela): carrega o shellenv antes de
  # procurar Python e Node, para achar o que o brew ja instalou.
  find_brew || true
  decidir_editor_video || true
  ensure_python || true
  ensure_node || true
  ensure_postgres || true
  ensure_ffmpeg || true
  ensure_drawtext || true
  ensure_pillow || true
  ensure_agy || true
  ensure_higgsfield || true
  ensure_autoeditor || true
  ensure_capcut || true
  ensure_ytdlp || true
  ensure_whisper || true
  ensure_whisper_model || true
  ensure_handy || true
  ensure_voicestudio || true
  ensure_editor_video || true

  printf '\n\033[1mSimulador ACE e ACE Audiovisual: requisitos do Mac\033[0m\n'
  printf '%s' "$READY$PENDING$AVISOS"
  printf '\nQuem edita no Adobe Premiere Pro ou no CapCut: rode tsa-editor --estado para ver o que falta.\n'
  if [ "$PENDING_N" = 0 ]; then
    printf '\nTudo pronto. O simulador ACE ja pode rodar pelo app.\n'
    return 0
  fi
  printf '\nFalta resolver %s item(ns), marcados com x acima. So o que depende deles espera; o resto ja funciona.\n' "$PENDING_N"
  # O login do agy nao trava o simulador: ele serve a leitura de video pelo Gemini e ao ACE Operacional.
  [ -n "$AGY_PENDENTE" ] && printf 'Sem o login do Antigravity, so a leitura de video pelo Gemini e o ACE Operacional esperam.\n'
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
