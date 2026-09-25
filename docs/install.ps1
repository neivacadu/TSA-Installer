# Instalador do TSA (Windows) - comando unico, sem GitHub CLI, sem conta no GitHub e sem administrador.
#   irm https://neivacadu.github.io/TSA-Installer/install.ps1 | iex
#
# 1. Libera scripts locais para este usuario (ExecutionPolicy RemoteSigned, escopo CurrentUser).
# 2. Instala, so o que falta, tudo dentro do perfil do usuario:
#    Node LTS (zip oficial, SHA-256 conferido), Git para Windows portatil (o Claude Code e os hooks
#    do TSA usam o Git Bash), Python 3.12 (os hooks do TSA sao Python) e o agente: Claude Code
#    pelo instalador oficial, ou Codex pelo npm.
#    Poe %USERPROFILE%\.local\bin no PATH do usuario: e onde o TSA escreve cofre, tsa-jev e
#    tsa-publicar.
# 3. Baixa o instalador do TSA (.exe) da release, confere o SHA-256 e instala em modo silencioso
#    (por usuario, em %LOCALAPPDATA%\Programs). O DNA da TSA ja vai embutido no app.
#
# Controles (variaveis de ambiente, antes do comando):
#   TSA_RELEASE_TAG=<tag>   release do TSA-Installer (padrao abaixo).
#   TSA_EXE_URL=<url>       endereco do .exe; troca o da release. O SHA-256 vem de TSA_EXE_SHA256
#                           ou do checksums-sha256.txt ao lado do .exe.
#   TSA_EXE_SHA256=<hex>    SHA-256 esperado do .exe.
#   TSA_AGENTE=claude|codex|ambos   agente a instalar (padrao claude).
#   TSA_SKIP_PREREQS=1      instala so o app.
#   TSA_ONLY_PREREQS=1      so prepara a maquina, sem baixar nem instalar o app.
#   TSA_SEM_PYTHON=1        nao instala o Python (os hooks do TSA ficam desligados).
#   TSA_SEM_MIDIA=1         nao instala ffmpeg, yt-dlp e whisper-cli (tsa-corte, tsa-voz, tsa-visao).
#   TSA_BAIXAR_MODELO=1     baixa tambem o modelo de transcricao de 1,6 GB para ~\.cache\whisper.
# Tudo fica em funcoes e so roda na chamada de Main, na ultima linha.

function Set-TsaGlobals {
  $script:ReleaseTag = if ($env:TSA_RELEASE_TAG) { $env:TSA_RELEASE_TAG } else { 'tsa-installer-v0.4.13-adhoc' }
  $script:BaseUrl = "https://github.com/neivacadu/TSA-Installer/releases/download/$script:ReleaseTag"
  $script:ExeName = 'tsa-windows-x64.exe'
  $script:ExeUrl = if ($env:TSA_EXE_URL) { $env:TSA_EXE_URL } else { "$script:BaseUrl/$script:ExeName" }
  $script:Agente = if ($env:TSA_AGENTE) { $env:TSA_AGENTE.ToLower() } else { 'claude' }
  $script:Programs = Join-Path $env:LOCALAPPDATA 'Programs'
  $script:NodeDir = Join-Path $script:Programs 'nodejs'
  $script:GitDir = Join-Path $script:Programs 'Git'
  $script:LocalBin = Join-Path $env:USERPROFILE '.local\bin'
  $script:MidiaDir = Join-Path $script:Programs 'tsa-midia'
  $script:WhisperDir = Join-Path $env:USERPROFILE '.cache\whisper'
  $script:Tmp = Join-Path $env:TEMP ("tsa-install-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $script:Avisos = New-Object System.Collections.Generic.List[string]
  $script:Feitos = New-Object System.Collections.Generic.List[string]
}

function Say([string]$texto) { Write-Host "==> $texto" }
function Aviso([string]$texto) { $script:Avisos.Add($texto); Write-Host "AVISO: $texto" -ForegroundColor Yellow }
function Feito([string]$texto) { $script:Feitos.Add($texto); Write-Host "OK: $texto" -ForegroundColor Green }
function Die([string]$texto) {
  Write-Host "ERRO: $texto" -ForegroundColor Red
  throw "tsa-install: $texto"
}

function Baixa([string]$url, [string]$destino) {
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $destino -TimeoutSec 600
}

# tar.exe do Windows 10+ abre zip muito mais rapido que o Expand-Archive do PowerShell 5.1.
function Extrai([string]$zip, [string]$destino) {
  New-Item -ItemType Directory -Force -Path $destino | Out-Null
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path $tar) {
    & $tar -xf $zip -C $destino
    if ($LASTEXITCODE -eq 0) { return }
  }
  Expand-Archive -LiteralPath $zip -DestinationPath $destino -Force
}

function Sha256([string]$arquivo) { (Get-FileHash -Algorithm SHA256 -LiteralPath $arquivo).Hash.ToLower() }

# PATH do usuario: acrescenta no comeco, uma vez so, e ja vale nesta sessao.
function Add-UserPath([string]$pasta) {
  $atual = [Environment]::GetEnvironmentVariable('Path', 'User')
  $partes = @($atual -split ';' | Where-Object { $_ })
  if (-not ($partes | Where-Object { $_.TrimEnd('\') -ieq $pasta.TrimEnd('\') })) {
    [Environment]::SetEnvironmentVariable('Path', (@($pasta) + $partes) -join ';', 'User')
  }
  if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $pasta.TrimEnd('\') })) {
    $env:Path = "$pasta;$env:Path"
  }
}

# Comando real no PATH, fora do atalho da Microsoft Store (WindowsApps), que so abre a loja.
function Find-Real([string]$nome) {
  Get-Command $nome -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
}

function Set-Policy {
  $atual = Get-ExecutionPolicy -Scope CurrentUser
  if ($atual -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Feito "ExecutionPolicy do usuario ja permite scripts ($atual)"
    return
  }
  try {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    Feito 'ExecutionPolicy RemoteSigned para este usuario'
  } catch {
    # Politica de grupo manda mais que o usuario; o TSA chama o PowerShell com -ExecutionPolicy Bypass.
    Aviso "ExecutionPolicy nao mudou ($($_.Exception.Message)). O TSA segue funcionando pelos .cmd."
  }
}

function Install-Node {
  $node = Find-Real 'node'
  if ($node) {
    $versao = (& $node.Source --version) -replace '^v', ''
    if ([int]($versao.Split('.')[0]) -ge 20) { Feito "Node $versao ja instalado"; return }
    Aviso "Node $versao e velho; instalando o LTS em $script:NodeDir"
  }
  Say 'Instalando Node LTS (zip oficial, por usuario)...'
  $lista = Invoke-RestMethod -UseBasicParsing https://nodejs.org/dist/index.json
  $lts = $lista | Where-Object { $_.lts -and $_.files -contains 'win-x64-zip' } | Select-Object -First 1
  if (-not $lts) { Die 'nao achei a versao LTS do Node em nodejs.org' }
  $v = $lts.version
  $zip = "node-$v-win-x64.zip"
  Baixa "https://nodejs.org/dist/$v/$zip" (Join-Path $script:Tmp $zip)
  $somas = (Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$v/SHASUMS256.txt").Content
  $esperado = ($somas -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($zip))$" } | Select-Object -First 1) -replace '\s.*$', ''
  if (-not $esperado -or $esperado.ToLower() -ne (Sha256 (Join-Path $script:Tmp $zip))) { Die "SHA-256 do $zip nao confere" }
  if (Test-Path $script:NodeDir) { Remove-Item -Recurse -Force $script:NodeDir }
  Extrai (Join-Path $script:Tmp $zip) $script:Programs
  Rename-Item (Join-Path $script:Programs "node-$v-win-x64") $script:NodeDir
  Add-UserPath $script:NodeDir
  Feito "Node $v em $script:NodeDir"
}

function Install-Git {
  $bash = Join-Path $script:GitDir 'bin\bash.exe'
  $git = Find-Real 'git'
  if ($git -or (Test-Path $bash)) {
    Feito 'Git para Windows ja instalado'
  } else {
    Say 'Instalando Git para Windows portatil (por usuario)...'
    $rel = Invoke-RestMethod -UseBasicParsing https://api.github.com/repos/git-for-windows/git/releases/latest
    $asset = $rel.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
    if (-not $asset) { Die 'nao achei o PortableGit na release do git-for-windows' }
    $sfx = Join-Path $script:Tmp $asset.name
    Baixa $asset.browser_download_url $sfx
    # O GitHub publica o sha256 de cada arquivo da release (campo digest).
    if ($asset.digest -and $asset.digest -like 'sha256:*') {
      if ($asset.digest.Substring(7).ToLower() -ne (Sha256 $sfx)) { Die "SHA-256 do $($asset.name) nao confere" }
    } else {
      Aviso "a release do Git nao publicou o sha256 de $($asset.name); instalado so pela origem https"
    }
    Start-Process -FilePath $sfx -ArgumentList '-y', "-o`"$script:GitDir`"" -Wait -WindowStyle Hidden
    if (-not (Test-Path $bash)) { Die 'o Git portatil nao extraiu' }
    $post = Join-Path $script:GitDir 'post-install.bat'
    if (Test-Path $post) {
      Start-Process -FilePath (Join-Path $script:GitDir 'git-bash.exe') -ArgumentList '--no-needs-console', '--hide', '--no-cd', '--command=post-install.bat' -WorkingDirectory $script:GitDir -Wait -WindowStyle Hidden
    }
    Add-UserPath (Join-Path $script:GitDir 'cmd')
    Feito "Git $($rel.tag_name) em $script:GitDir"
  }
  # O Claude Code acha o Git Bash por esta variavel quando ele nao esta no lugar padrao.
  if ((Test-Path $bash) -and -not [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'User')
    $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
  }
}

function Test-Python {
  # No PowerShell 5.1, stderr de programa com Stop vira erro fatal; aqui so o codigo de saida conta.
  $ErrorActionPreference = 'Continue'
  $py = Find-Real 'py'
  if ($py) { & $py.Source -3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null; if ($LASTEXITCODE -eq 0) { return $true } }
  $python = Find-Real 'python'
  if ($python) { & $python.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null; if ($LASTEXITCODE -eq 0) { return $true } }
  return $false
}

function Install-Python {
  if ($env:TSA_SEM_PYTHON -eq '1') { Aviso 'Python pulado (TSA_SEM_PYTHON=1): os hooks do TSA ficam desligados'; return }
  if (Test-Python) { Feito 'Python 3.10+ ja instalado'; return }
  Say 'Instalando Python 3.12 (por usuario)...'
  $exe = Join-Path $script:Tmp 'python-3.12.10-amd64.exe'
  Baixa 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' $exe
  $sig = Get-AuthenticodeSignature -LiteralPath $exe
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
    Die "o instalador do Python nao tem a assinatura da Python Software Foundation ($($sig.Status))"
  }
  $p = Start-Process -FilePath $exe -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=1', 'InstallLauncherAllUsers=0', 'Include_test=0', 'Shortcuts=0' -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    # 1601/1603: o Windows Installer nao atende (sessao remota, servico parado). O zip embutivel
    # do python.org nao usa MSI; os hooks e os comandos do TSA so usam a biblioteca padrao.
    Aviso "o instalador do Python saiu com $($p.ExitCode); usando o Python embutivel (zip)"
    Install-PythonEmbed
    return
  }
  foreach ($d in @("$env:LOCALAPPDATA\Programs\Python\Python312", "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts", "$env:LOCALAPPDATA\Programs\Python\Launcher")) {
    if (Test-Path $d) { Add-UserPath $d }
  }
  if (Test-Python) { Feito 'Python 3.12 instalado' } else { Aviso 'Python instalado, mas o py -3 ainda nao responde nesta janela' }
}

function Install-PythonEmbed {
  $zip = Join-Path $script:Tmp 'python-3.12.10-embed-amd64.zip'
  Baixa 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' $zip
  $destino = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312-embed'
  if (Test-Path $destino) { Remove-Item -Recurse -Force $destino }
  Extrai $zip $destino
  $sig = Get-AuthenticodeSignature -LiteralPath (Join-Path $destino 'python.exe')
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
    Remove-Item -Recurse -Force $destino
    Die "o python.exe do zip nao tem a assinatura da Python Software Foundation ($($sig.Status))"
  }
  Add-UserPath $destino
  if (Test-Python) { Feito 'Python 3.12 (embutivel) instalado' } else { Aviso 'Python embutivel copiado, mas nao respondeu' }
}

function Install-Claude {
  if (Find-Real 'claude') { Feito 'Claude Code ja instalado'; return }
  Say 'Instalando Claude Code (instalador oficial, por usuario)...'
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  & $ps -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://claude.ai/install.ps1 | iex"
  Add-UserPath $script:LocalBin
  if (Test-Path (Join-Path $script:LocalBin 'claude.exe')) { Feito 'Claude Code instalado' } else { Aviso 'o instalador do Claude Code terminou, mas claude.exe nao apareceu em .local\bin' }
}

function Install-Codex {
  if (Find-Real 'codex') { Feito 'Codex ja instalado'; return }
  $npm = Find-Real 'npm'
  if (-not $npm) { $npm = Get-Command (Join-Path $script:NodeDir 'npm.cmd') -ErrorAction SilentlyContinue }
  if (-not $npm) { Aviso 'npm nao encontrado; Codex nao instalado'; return }
  Say 'Instalando Codex (npm, por usuario)...'
  & $npm.Source install -g '@openai/codex' | Out-Host
  $prefixo = (& $npm.Source config get prefix).Trim()
  if ($prefixo) { Add-UserPath $prefixo }
  if (Find-Real 'codex') { Feito 'Codex instalado' } else { Aviso 'npm terminou, mas o comando codex nao apareceu' }
}

# Arquivo de release do GitHub com o sha256 que o proprio GitHub publica (campo digest).
function Get-GhAsset([string]$repo, [string]$release, [string]$padrao) {
  $url = if ($release -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" } else { "https://api.github.com/repos/$repo/releases/tags/$release" }
  $rel = Invoke-RestMethod -UseBasicParsing $url
  $asset = $rel.assets | Where-Object { $_.name -match $padrao } | Select-Object -First 1
  if (-not $asset) { Die "nao achei $padrao na release $release de $repo" }
  if (-not ($asset.digest -like 'sha256:*')) { Die "a release $release de $repo nao publica o sha256 de $($asset.name)" }
  return [pscustomobject]@{ Nome = $asset.name; Url = $asset.browser_download_url; Sha = $asset.digest.Substring(7).ToLower(); Tag = $rel.tag_name }
}

function Get-Conferido($asset) {
  $arquivo = Join-Path $script:Tmp $asset.Nome
  Baixa $asset.Url $arquivo
  if ((Sha256 $arquivo) -ne $asset.Sha) { Die "SHA-256 do $($asset.Nome) nao confere" }
  return $arquivo
}

# ffmpeg com drawtext e libass (build GPL do BtbN), yt-dlp e whisper-cli, tudo por usuario.
function Install-Midia {
  if ($env:TSA_SEM_MIDIA -eq '1') { Aviso 'midia pulada (TSA_SEM_MIDIA=1): tsa-corte, tsa-voz e tsa-visao sem ferramentas'; return }
  $bin = Join-Path $script:MidiaDir 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  if (Find-Real 'ffmpeg') {
    Feito 'ffmpeg ja instalado'
  } else {
    Say 'Instalando ffmpeg (build GPL do BtbN, por usuario)...'
    $a = Get-GhAsset 'BtbN/FFmpeg-Builds' 'latest' '^ffmpeg-n8\.1-latest-win64-gpl-8\.1\.zip$'
    $zip = Get-Conferido $a
    $destino = Join-Path $script:MidiaDir 'ffmpeg'
    if (Test-Path $destino) { Remove-Item -Recurse -Force $destino }
    Extrai $zip $script:Tmp
    Move-Item (Join-Path $script:Tmp ([IO.Path]::GetFileNameWithoutExtension($a.Nome))) $destino
    Add-UserPath (Join-Path $destino 'bin')
    Feito 'ffmpeg 8.1 instalado'
  }
  if (Find-Real 'yt-dlp') {
    Feito 'yt-dlp ja instalado'
  } else {
    Say 'Instalando yt-dlp...'
    $a = Get-GhAsset 'yt-dlp/yt-dlp' 'latest' '^yt-dlp\.exe$'
    Copy-Item (Get-Conferido $a) (Join-Path $bin 'yt-dlp.exe') -Force
    Feito "yt-dlp $($a.Tag) instalado"
  }
  if (Find-Real 'whisper-cli') {
    Feito 'whisper-cli ja instalado'
  } else {
    Say 'Instalando whisper-cli (whisper.cpp v1.9.2)...'
    $a = Get-GhAsset 'ggml-org/whisper.cpp' 'v1.9.2' '^whisper-bin-x64\.zip$'
    $zip = Get-Conferido $a
    $destino = Join-Path $script:MidiaDir 'whisper'
    if (Test-Path $destino) { Remove-Item -Recurse -Force $destino }
    Extrai $zip $destino
    $cli = Get-ChildItem -LiteralPath $destino -Recurse -Filter 'whisper-cli.exe' | Select-Object -First 1
    if (-not $cli) { Die 'o zip do whisper.cpp nao trouxe o whisper-cli.exe' }
    Add-UserPath $cli.DirectoryName
    Feito 'whisper-cli v1.9.2 instalado'
  }
  Add-UserPath $bin
  New-Item -ItemType Directory -Force -Path $script:WhisperDir | Out-Null
  # Detector de voz do tsa-editor fala-limpa (mesmo arquivo e mesmo sha256 do install.sh).
  $silero = Join-Path $script:WhisperDir 'ggml-silero-v5.1.2.bin'
  if (-not (Test-Path $silero)) {
    Baixa 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin' "$silero.part"
    if ((Sha256 "$silero.part") -ne '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf') {
      Remove-Item "$silero.part"; Aviso 'o modelo Silero veio diferente do conferido; nao instalado'
    } else { Move-Item "$silero.part" $silero; Feito 'modelo Silero em ~\.cache\whisper' }
  }
  $modelo = Join-Path $script:WhisperDir 'ggml-large-v3-turbo.bin'
  if (Test-Path $modelo) {
    Feito 'modelo de transcricao ja baixado'
  } elseif ($env:TSA_BAIXAR_MODELO -eq '1') {
    Say 'Baixando o modelo de transcricao (1,6 GB)...'
    Baixa 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin' "$modelo.part"
    if ((Get-Item "$modelo.part").Length -ne 1624555275) { Remove-Item "$modelo.part"; Aviso 'o modelo de transcricao veio incompleto; rode de novo' }
    else { Move-Item "$modelo.part" $modelo; Feito 'modelo de transcricao baixado' }
  } else {
    Aviso 'modelo de transcricao (1,6 GB) nao baixado; para baixar, rode de novo com $env:TSA_BAIXAR_MODELO=1 e $env:TSA_ONLY_PREREQS=1'
  }
}

function Install-Prereqs {
  New-Item -ItemType Directory -Force -Path $script:Programs, $script:LocalBin | Out-Null
  Add-UserPath $script:LocalBin
  Feito "$script:LocalBin no PATH do usuario"
  Install-Node
  Install-Git
  Install-Python
  Install-Midia
  switch ($script:Agente) {
    'claude' { Install-Claude }
    'codex' { Install-Codex }
    'ambos' { Install-Claude; Install-Codex }
    default { Aviso "TSA_AGENTE=$($script:Agente) nao e claude, codex nem ambos; nenhum agente instalado" }
  }
}

function Get-ExpectedSha {
  if ($env:TSA_EXE_SHA256) { return $env:TSA_EXE_SHA256.ToLower() }
  $nome = [IO.Path]::GetFileName(([Uri]$script:ExeUrl).AbsolutePath)
  $base = $script:ExeUrl.Substring(0, $script:ExeUrl.LastIndexOf('/'))
  $somas = (Invoke-WebRequest -UseBasicParsing "$base/checksums-sha256.txt").Content
  if ($somas -is [byte[]]) { $somas = [Text.Encoding]::UTF8.GetString($somas) }
  $linha = $somas -split "`n" | Where-Object { ($_ -split '\s+')[1] -eq $nome } | Select-Object -First 1
  if (-not $linha) { Die "checksum ausente para $nome" }
  return ($linha -split '\s+')[0].ToLower()
}

function Find-TsaExe {
  $chaves = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DisplayName -eq 'TSA' }
  foreach ($c in $chaves) {
    # O NSIS do app grava o caminho no DisplayIcon ("...\TSA.exe,0"); o InstallLocation vem vazio.
    $candidatos = @("$($c.DisplayIcon)" -replace ',\d+$', '' -replace '"', '')
    if ($c.InstallLocation) { $candidatos += "$($c.InstallLocation.TrimEnd('\'))\TSA.exe" }
    foreach ($candidato in $candidatos) {
      if ($candidato -and $candidato -like '*TSA.exe' -and (Test-Path -LiteralPath $candidato)) { return $candidato }
    }
  }
  # A pasta leva o nome do pacote (orca), nao o do produto.
  foreach ($pasta in 'orca', 'TSA') {
    $padrao = Join-Path $script:Programs "$pasta\TSA.exe"
    if (Test-Path $padrao) { return $padrao }
  }
  return $null
}

function Install-App {
  $exe = Join-Path $script:Tmp 'tsa-setup.exe'
  Say "Baixando o TSA de $($script:ExeUrl)..."
  Baixa $script:ExeUrl $exe
  $esperado = Get-ExpectedSha
  if ($esperado -ne (Sha256 $exe)) { Die 'SHA-256 do instalador do TSA nao confere (download corrompido). Tente de novo.' }
  Feito 'SHA-256 do instalador conferido'
  $aberto = Get-Process -Name 'TSA' -ErrorAction SilentlyContinue
  if ($aberto) {
    Say 'O TSA esta aberto; pedindo para ele fechar...'
    $aberto | ForEach-Object { [void]$_.CloseMainWindow() }
    Wait-Process -Name 'TSA' -Timeout 30 -ErrorAction SilentlyContinue
    if (Get-Process -Name 'TSA' -ErrorAction SilentlyContinue) {
      Die 'o TSA continua aberto. Feche o TSA e rode o comando de novo.'
    }
  }
  Say 'Instalando o TSA (silencioso, por usuario)...'
  $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
  if ($p.ExitCode -ne 0) { Die "o instalador do TSA saiu com $($p.ExitCode)" }
  $app = Find-TsaExe
  if (-not $app) { Die 'o instalador terminou, mas nao achei o TSA.exe' }
  Feito "TSA instalado em $(Split-Path -Parent $app)"
}

function Main {
  $ErrorActionPreference = 'Stop'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Set-TsaGlobals
  if ([Environment]::Is64BitOperatingSystem -eq $false) { Die 'o TSA precisa do Windows 64 bits' }
  New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null
  try {
    Set-Policy
    if ($env:TSA_SKIP_PREREQS -ne '1') { Install-Prereqs }
    if ($env:TSA_ONLY_PREREQS -ne '1') { Install-App }
    Write-Host ''
    Write-Host 'Pronto. Feche e abra o terminal para o PATH novo valer.' -ForegroundColor Green
    if ($script:Avisos.Count -gt 0) {
      Write-Host 'Pendencias:' -ForegroundColor Yellow
      $script:Avisos | ForEach-Object { Write-Host "  - $_" }
    }
  } finally {
    Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue
  }
}

Main
