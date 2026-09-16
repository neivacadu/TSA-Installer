#!/usr/bin/env bash
# Instalador do TSA (macOS) — comando unico, sem GitHub CLI.
#   curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | bash
# Baixa o app do release publico, confere o checksum SHA-256, instala em /Applications
# e remove a quarentena. O DNA da TSA ja vai embutido e assinado dentro do app.
set -euo pipefail

RELEASE_TAG="${TSA_RELEASE_TAG:-tsa-installer-v0.1.3-adhoc}"
BASE_URL="https://github.com/neivacadu/TSA-Installer/releases/download/${RELEASE_TAG}"
APP_NAME="${TSA_APP_NAME:-TSA.app}"

say(){ printf '\033[0;36m%s\033[0m\n' "$1"; }
ok(){ printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
die(){ printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Este instalador e para macOS. Para Windows, use o instalador do Windows."
command -v curl >/dev/null || die "curl nao encontrado."

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  ARTIFACT="tsa-macos-arm64.dmg" ;;
  x86_64) ARTIFACT="tsa-macos-x64.dmg" ;;
  *) die "Arquitetura nao suportada: $ARCH" ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tsa-install.XXXXXX")"
MOUNT=""
cleanup(){ [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

say "Baixando o TSA ($ARCH)..."
curl -fL --progress-bar "$BASE_URL/$ARTIFACT" -o "$TMP_DIR/$ARTIFACT" || die "Falha ao baixar $ARTIFACT"
curl -fsSL "$BASE_URL/checksums-sha256.txt" -o "$TMP_DIR/checksums-sha256.txt" || die "Falha ao baixar os checksums"

say "Conferindo integridade..."
EXPECTED="$(awk -v n="$ARTIFACT" '$2==n{print $1}' "$TMP_DIR/checksums-sha256.txt")"
[ -n "$EXPECTED" ] || die "Checksum ausente para $ARTIFACT"
ACTUAL="$(shasum -a 256 "$TMP_DIR/$ARTIFACT" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "Checksum invalido (download corrompido). Tente de novo."
ok "Download integro"

say "Instalando..."
MOUNT="$(hdiutil attach "$TMP_DIR/$ARTIFACT" -nobrowse -readonly | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | head -1)"
[ -n "$MOUNT" ] || die "Nao foi possivel montar o instalador."
SRC_APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$SRC_APP" ] || die "Nenhum .app encontrado no pacote."

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
APP_TARGET="$DEST/$APP_NAME"
rm -rf "$APP_TARGET"
ditto "$SRC_APP" "$APP_TARGET" || die "Falha ao copiar o app."
# ad-hoc: re-assina e remove a quarentena do Gatekeeper para abrir sem "app danificado"
codesign --force --deep --sign - "$APP_TARGET" >/dev/null 2>&1 || true
/usr/bin/xattr -dr com.apple.quarantine "$APP_TARGET" >/dev/null 2>&1 || true
ok "$APP_NAME instalado em $DEST"

printf '\n\033[1;32mTSA instalado.\033[0m\n'
printf 'Abra pelo Launchpad ou Aplicativos. Na primeira vez, se aparecer "editor desconhecido":\n'
printf '  clique com o botao direito no app, Abrir, Abrir.\n'
printf 'O DNA da TSA ja vem dentro e e aplicado no primeiro uso.\n'
