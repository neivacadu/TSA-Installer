#!/usr/bin/env bash
set -euo pipefail

RELEASE_TAG="${TSA_RELEASE_TAG:-tsa-installer-v0.1.3-adhoc}"
BASE_URL="https://github.com/neivacadu/TSA-Installer/releases/download/${RELEASE_TAG}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ARTIFACT="tsa-macos-arm64.dmg" ;;
  x86_64) ARTIFACT="tsa-macos-x64.dmg" ;;
  *) echo "Arquitetura não suportada: $ARCH" >&2; exit 2 ;;
esac
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tsa-install.XXXXXX")"
cleanup() { [ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
command -v gh >/dev/null || { echo "Instale o GitHub CLI e faça gh auth login antes de continuar" >&2; exit 1; }
DMG="$TMP_DIR/$ARTIFACT"
gh release download "$RELEASE_TAG" --repo neivacadu/TSA-Installer --pattern "$ARTIFACT" --pattern checksums-sha256.txt --dir "$TMP_DIR" --clobber
EXPECTED="$(awk -v name="$ARTIFACT" '$2 == name {print $1}' "$TMP_DIR/checksums-sha256.txt")"
[ -n "$EXPECTED" ] || { echo "Checksum ausente para $ARTIFACT" >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum inválido para $ARTIFACT" >&2; exit 1; }
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly | sed -n 's#.*\t\(/Volumes/.*\)$#\1#p' | head -1)"
[ -n "$MOUNT" ] || { echo "Não foi possível montar o instalador" >&2; exit 1; }
APP_TARGET="/Applications/TSA Teste.app"
rm -rf "$APP_TARGET"
ditto "$MOUNT/TSA.app" "$APP_TARGET"
codesign --verify --deep --strict "$APP_TARGET"
PROFILE="$HOME/Library/Application Support/TSA Teste"
printf 'TSA instalado com sucesso em: %s\n' "$APP_TARGET"
printf 'Perfil limpo reservado em: %s\n' "$PROFILE"
printf 'Para iniciar o teste limpo, rode:\n'
printf '%q --user-data-dir=%q\n' "$APP_TARGET/Contents/MacOS/TSA" "$PROFILE"
