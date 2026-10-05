#!/bin/bash
# Atualizar o TSA agora pelo painel (macOS) — INSTALAR-F2-CONTRATO v2.0, seção 4.5.
#   curl -fsSL https://ace.caduneiva.com/apptsa/atualizar.sh | bash
# Invólucro curto: roda a cópia local do agendador, que o app mantém, com --agora. A troca é
# sempre do agendador; este arquivo não baixa nem troca nada.
set -euo pipefail

TSA_SCRIPT_VERSAO="2026.10.02.1"

ATUALIZADOR="$HOME/Library/Application Support/TSA/atualizador/atualizar.sh"

main(){
  if [ -f "$ATUALIZADOR" ]; then
    exec /bin/bash "$ATUALIZADOR" --agora
  fi
  printf 'Este Mac ainda não tem o atualizador do TSA. Rode o instalador:\n'
  printf '  curl -fsSL https://ace.caduneiva.com/apptsa/install.sh | bash\n'
  exit 1
}

main "$@"
