# Atualizar o TSA agora pelo painel (Windows) - INSTALAR-F4-WINDOWS-CONTRATO v1.4, seção 3.2.
#   irm https://ace.caduneiva.com/apptsa/atualizar.ps1 | iex
# Invólucro curto: roda a cópia local do atualizador, que o app mantém, com -Agora, pela linha
# de chamada da seção 7.1. A troca é sempre do atualizador; este arquivo não baixa nem troca nada.
# Não usa exit: com irm | iex ele fecharia a janela. O resultado fica em $LASTEXITCODE.

$TSA_SCRIPT_VERSAO = "2026.10.06.1"

function Main {
  $local = $env:LOCALAPPDATA
  if (-not $local) { $local = [Environment]::GetFolderPath('LocalApplicationData') }
  $atualizador = Join-Path $local 'TSA\atualizador\atualizar.ps1'
  if (Test-Path -LiteralPath $atualizador -PathType Leaf) {
    $sys = 'System32'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { $sys = 'Sysnative' }
    $ps = Join-Path $env:SystemRoot "$sys\WindowsPowerShell\v1.0\powershell.exe"
    # A política de execução vale só para esse processo.
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $atualizador -Agora
    return
  }
  Write-Host 'Este computador ainda não tem o atualizador do TSA. Rode o instalador:'
  Write-Host '  irm https://ace.caduneiva.com/apptsa/install.ps1 | iex'
  $global:LASTEXITCODE = 1
}

Main
