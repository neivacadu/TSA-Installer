# Testa o instalador do painel para Windows: docs/instalartsa/install.ps1 e atualizar.ps1
# (INSTALAR-F4-WINDOWS-CONTRATO v1.4, secoes 4, 5 e 6.2). Este arquivo e so ASCII: roda por -File.
# Os scripts testados tem acento e nao tem BOM; por isso sao lidos como UTF-8 e rodados em memoria,
# como o irm | iex faz. Nunca rode o install.ps1 por -File.
#
# Roda so em maquina de teste: grava e apaga itens de teste no Gerenciador de Credenciais do usuario
# (tsa-convite-pendente e tsa-atualizador:<uuid de teste>) e, no caso D, uma chave de teste em HKCU.
# Nao fala com a Central de verdade: sobe scripts/fixtures/central-falsa.ps1 em localhost.
# Convite e credencial de teste sao derivados de um numero sorteado a cada execucao; nao estao no fonte.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-instalartsa.ps1 -MaquinaDeTeste `
#     -Vetores <vetores-manifesto.json do app> -ChavesApp <app-trusted-keys.json do app>
#
# Modos (-Modo):
#   tudo         verificador, casos com Central falsa e provas da secao 5.4 com instalador falso (padrao)
#   verificador  so o verificador (11 vetores, manifesto real, tempo)
#   console      caminho feliz numa janela de console de verdade, com o convite digitado por SendKeys
#                (precisa de sessao interativa); prova o Read-Host -AsSecureString e as recusas reais
#   nsis         prova da secao 5.4 com um instalador NSIS de verdade (-Nsis <caminho do .exe>)
#   procurar     procura o convite e a credencial da ultima execucao nas transcricoes (-Transcricoes) e
#                no log de eventos do PowerShell (T-INS-25 ampliado; rodar como administrador)
# -SemAmbiente troca as recusas de ambiente (console, administrador) por nada: para rodar por SSH.
param(
  [switch]$MaquinaDeTeste,
  [string]$Vetores = '',
  [string]$ChavesApp = '',
  [string]$Trabalho = '',
  [string]$Modo = 'tudo',
  [string]$Nsis = '',
  [string]$Transcricoes = '',
  [switch]$SemAmbiente,
  [int]$Porta = 58931
)
$ErrorActionPreference = 'Stop'
if (-not $MaquinaDeTeste) { Write-Host 'Este teste mexe no Gerenciador de Credenciais do usuario. Rode so em maquina de teste, com -MaquinaDeTeste.'; exit 2 }

$EU = $MyInvocation.MyCommand.Path
$RAIZ = Split-Path -Parent (Split-Path -Parent $EU)
$INSTALL = Join-Path $RAIZ 'docs\instalartsa\install.ps1'
$ATUALIZAR = Join-Path $RAIZ 'docs\instalartsa\atualizar.ps1'
$CENTRAL = Join-Path $RAIZ 'scripts\fixtures\central-falsa.ps1'
$REAL = Join-Path $RAIZ 'scripts\fixtures\manifesto-real-20261002.json'
if (-not $Trabalho) { $Trabalho = Join-Path $env:TEMP 'tsa-instalartsa-teste' }
$TRAB = $Trabalho
$UTF8 = New-Object System.Text.UTF8Encoding $false
$PASSOU = 0
$FALHOU = 0
$FALHAS = New-Object System.Collections.Generic.List[string]

function Confere([string]$nome, $condicao) {
  if ($condicao -is [bool] -and $condicao) { $script:PASSOU++; Write-Host "  ok     $nome" }
  else {
    $script:FALHOU++; $script:FALHAS.Add($nome); Write-Host "  FALHOU $nome"
    if ($script:OUT) { ($script:OUT -split "`n") | Select-Object -Last 12 | ForEach-Object { Write-Host "       | $_" } }
  }
}
function Sha256Texto([string]$t) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  try { return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Sha256Arquivo([string]$p) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  try { return ([BitConverter]::ToString($h.ComputeHash([IO.File]::ReadAllBytes($p))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
# Segredo de teste: 43 caracteres base64url tirados de SHA-256(numero sorteado + rotulo).
function Derivar([string]$nonce, [string]$rotulo) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  try { $b = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($nonce + ':' + $rotulo)) } finally { $h.Dispose() }
  return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
# Quantas vezes o texto aparece nos bytes de um arquivo, em ASCII e em UTF-16.
function Contem-Segredo([byte[]]$bytes, [string]$segredo) {
  $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
  if ($latin.Contains($segredo)) { return $true }
  $largo = [Text.Encoding]::GetEncoding(28591).GetString([Text.Encoding]::Unicode.GetBytes($segredo))
  return $latin.Contains($largo)
}

# ---------------------------------------------------------------- modo procurar (administrador)
if ($Modo -eq 'procurar') {
  $nonce = [IO.File]::ReadAllText((Join-Path $TRAB 'nonce.txt')).Trim()
  $inicio = [DateTime]::Parse([IO.File]::ReadAllText((Join-Path $TRAB 'inicio.txt')).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
  $segredos = @((Derivar $nonce 'convite'), (Derivar $nonce 'credencial'))
  $marca = 'MARCA-' + $nonce
  $achou = 0; $arquivos = 0; $marcaTranscricao = 0
  if ($Transcricoes -and (Test-Path -LiteralPath $Transcricoes)) {
    foreach ($f in Get-ChildItem -LiteralPath $Transcricoes -Recurse -File) {
      $arquivos++
      $fluxo = New-Object System.IO.FileStream ($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      try { $b = New-Object 'byte[]' $fluxo.Length; [void]$fluxo.Read($b, 0, $b.Length) } finally { $fluxo.Dispose() }
      foreach ($s in $segredos) { if (Contem-Segredo $b $s) { $achou++; Write-Host "  SEGREDO em $($f.FullName)" } }
      if (Contem-Segredo $b $marca) { $marcaTranscricao++ }
    }
  }
  Write-Host "transcricoes: $arquivos arquivos; com a marca de controle: $marcaTranscricao; com segredo: $achou"
  $eventos = 0; $achouEv = 0; $blocos = 0
  foreach ($log in @('Microsoft-Windows-PowerShell/Operational', 'Windows PowerShell')) {
    $lista = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $inicio } -ErrorAction SilentlyContinue)
    foreach ($ev in $lista) {
      $eventos++
      $texto = [string]$ev.Message
      foreach ($p in $ev.Properties) { $texto += "`n" + [string]$p.Value }
      foreach ($s in $segredos) { if ($texto.Contains($s)) { $achouEv++; Write-Host "  SEGREDO no evento $($ev.Id) de $log" } }
      if ($ev.Id -eq 4104 -and $texto.Contains('function Pedir-Convite')) { $blocos++ }
    }
  }
  Write-Host "eventos do PowerShell desde ${inicio}: $eventos; blocos de script com o install.ps1 (4104): $blocos; com segredo: $achouEv"
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
  $t = (Get-ItemProperty "$pol\Transcription" -ErrorAction SilentlyContinue).EnableTranscripting
  $s = (Get-ItemProperty "$pol\ScriptBlockLogging" -ErrorAction SilentlyContinue).EnableScriptBlockLogging
  Write-Host "politicas agora: transcricao=$t blocos=$s"
  if ($achou + $achouEv -eq 0 -and $marcaTranscricao -gt 0 -and $blocos -gt 0) { Write-Host 'T-INS-25 ampliado: nenhuma ocorrencia'; exit 0 }
  Write-Host 'T-INS-25 ampliado: NAO provado (segredo achado, ou os registros nao estavam ligados)'; exit 1
}

# ---------------------------------------------------------------- carga do script testado
$TEXTO = [IO.File]::ReadAllText($INSTALL, $UTF8)
$corte = $TEXTO.LastIndexOf("`nMain -Perfil")
if ($corte -lt 0) { throw 'nao achei a chamada de Main no install.ps1' }
$erros = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($TEXTO, [ref]$null, [ref]$erros)
if ($erros.Count -gt 0) { $erros | ForEach-Object { Write-Host $_.Message }; throw 'install.ps1 com erro de sintaxe' }
. ([scriptblock]::Create($TEXTO.Substring(0, $corte)))
Carregar-Nativo
$CHAVES_REAIS = Chaves-Confiaveis

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TsaTesteCred {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL {
    public uint Flags; public uint Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob;
    public uint Persist; public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
  }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref CREDENTIAL c, uint f);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string a, uint t, uint f, out IntPtr c);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string a, uint t, uint f);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
  public static string Ler(string alvo) {
    IntPtr p;
    if (!CredReadW(alvo, 1, 0, out p)) return null;
    try {
      CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      return c.UserName + "|" + c.Type + "|" + c.Persist + "|" + Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
    } finally { CredFree(p); }
  }
  public static void Gravar(string alvo, string usuario, string segredo) {
    IntPtr b = Marshal.StringToCoTaskMemUni(segredo);
    try {
      CREDENTIAL c = new CREDENTIAL();
      c.Type = 1; c.TargetName = alvo; c.UserName = usuario; c.CredentialBlob = b; c.CredentialBlobSize = (uint)(segredo.Length * 2); c.Persist = 2;
      if (!CredWriteW(ref c, 0)) throw new InvalidOperationException("CredWrite " + Marshal.GetLastWin32Error());
    } finally { Marshal.FreeCoTaskMem(b); }
  }
  public static bool Apagar(string alvo) { return CredDeleteW(alvo, 1, 0); }
}
'@

$UUID = '1263da3d-dbf3-46ac-a49c-ea76340fd826'
$BUILD = '49d050c9f.20261006T120000Z'
function Limpar-Cred {
  [void][TsaTesteCred]::Apagar('tsa-convite-pendente')
  [void][TsaTesteCred]::Apagar("tsa-atualizador:$UUID")
}

# ---------------------------------------------------------------- assinador de teste
# Ed25519 (RFC 8032, 5.1.6) com as contas do proprio install.ps1. So para gerar manifestos de teste;
# o verificador e provado por fora, com os vetores do app e o manifesto real.
function Teste-Assinar([byte[]]$semente, [byte[]]$msg) {
  Ed-Iniciar
  $ed = $script:TSA_ED
  $sha = New-Object System.Security.Cryptography.SHA512CryptoServiceProvider
  $h = $sha.ComputeHash($semente)
  $a = New-Object 'byte[]' 32
  [Array]::Copy($h, $a, 32)
  $a[0] = [byte](([int]$a[0]) -band 248)
  $a[31] = [byte](((([int]$a[31]) -band 127)) -bor 64)
  $escalar = Ed-Le $a
  $pub = Ed-Codificar (Ed-Vezes $escalar $ed.Base)
  $pre = New-Object 'byte[]' (32 + $msg.Length)
  [Array]::Copy($h, 32, $pre, 0, 32); [Array]::Copy($msg, 0, $pre, 32, $msg.Length)
  $nonceR = [System.Numerics.BigInteger]::Remainder((Ed-Le $sha.ComputeHash($pre)), $ed.L)
  $pontoR = Ed-Codificar (Ed-Vezes $nonceR $ed.Base)
  $kb = New-Object 'byte[]' (64 + $msg.Length)
  [Array]::Copy($pontoR, 0, $kb, 0, 32); [Array]::Copy($pub, 0, $kb, 32, 32); [Array]::Copy($msg, 0, $kb, 64, $msg.Length)
  $k = [System.Numerics.BigInteger]::Remainder((Ed-Le $sha.ComputeHash($kb)), $ed.L)
  # Nomes diferentes de proposito: no PowerShell, $r e $R sao a mesma variavel.
  $parteS = [System.Numerics.BigInteger]::Remainder([System.Numerics.BigInteger]::Add($nonceR, [System.Numerics.BigInteger]::Multiply($k, $escalar)), $ed.L)
  $sig = New-Object 'byte[]' 64
  [Array]::Copy($pontoR, 0, $sig, 0, 32)
  $bytesS = $parteS.ToByteArray()
  [Array]::Copy($bytesS, 0, $sig, 32, [Math]::Min(32, $bytesS.Length))
  return @{ publica = $pub; assinatura = $sig }
}
$SEMENTE = New-Object 'byte[]' 32
(New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($SEMENTE)
$KEY_TESTE = 'tsa-teste-f4'
function Chaves-De-Teste {
  $pub = (Teste-Assinar $SEMENTE ([byte[]]@(1))).publica
  $der = [byte[]](@(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00) + $pub)
  return "{`n  `"$KEY_TESTE`": `"-----BEGIN PUBLIC KEY-----\n" + [Convert]::ToBase64String($der) + "\n-----END PUBLIC KEY-----\n`"`n}"
}
# Manifesto assinado pela chave de teste, em texto. $troca muda campos antes de assinar.
function Novo-Manifesto([string]$sha, [long]$bytes, [hashtable]$troca = @{}) {
  $m = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
  $a = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
  $a.Add('nome', 'tsa-windows-x64.exe'); $a.Add('sha256', $sha); $a.Add('bytes', [long]$bytes); $a.Add('url', '/v1/app/artefatos/' + $sha)
  $base = [ordered]@{ schema = 'tsa.app.release/v1'; produto = 'TSA'; app_id = 'com.trafegosa.orca-tsa'; versao = '0.5.0'; build_id = $BUILD
    versao_orca_base = '1.4.197'; plataforma = 'win32'; arquitetura = 'x64'; artefato = $a; dna_embutido = '1.0.21'; notas = ''
    publicado_em = '2026-10-06T12:10:00Z'; key_id = $KEY_TESTE }
  foreach ($k in $base.Keys) { $m.Add([string]$k, $base[$k]) }
  foreach ($k in $troca.Keys) {
    if ($k -like 'artefato.*') { $a[$k.Substring(9)] = $troca[$k] } else { $m[[string]$k] = $troca[$k] }
  }
  $hash = Tsa-Sha256Hex ($UTF8.GetBytes([string](Tsa-Canonico $m)))
  $m.Add('assinatura', [Convert]::ToBase64String((Teste-Assinar $SEMENTE ([Text.Encoding]::ASCII.GetBytes($hash))).assinatura))
  return [string](Tsa-Canonico $m)
}

# ---------------------------------------------------------------- 1. arquivos e verificador
function Testar-Verificador {
  Write-Host '1. arquivos servidos: UTF-8 sem BOM, so LF, versao declarada e proibicoes do contrato'
  foreach ($arq in @($INSTALL, $ATUALIZAR)) {
    $b = [IO.File]::ReadAllBytes($arq); $nome = [IO.Path]::GetFileName($arq); $t = $UTF8.GetString($b)
    Confere "$nome sem BOM e sem CR" (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) -and -not $t.Contains("`r"))
    Confere "$nome declara `$TSA_SCRIPT_VERSAO uma vez, no formato" ([regex]::Matches($t, '(?m)^\$TSA_SCRIPT_VERSAO = "[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+"$').Count -eq 1)
    $codigo = ($t -split "`n" | Where-Object { $_.Trim() -notmatch '^#' -and $_ -notmatch 'Write-Host' }) -join "`n"
    # A unica mencao permitida: a funcao vazia que anula Set-ExecutionPolicy no preparo das ferramentas.
    $codigo = $codigo.Replace('function Set-ExecutionPolicy { }', '')
    Confere "$nome nao usa Start-Transcript, Set-ExecutionPolicy, cmdkey, curl, BITS, Invoke-WebRequest, iex, Authenticode nem exit" `
      ($codigo -notmatch 'Start-Transcript|Set-ExecutionPolicy|cmdkey|curl(\.exe)?\b|Start-BitsTransfer|Invoke-WebRequest|Invoke-RestMethod|Invoke-Expression|\biex\b|\birm\b|Get-AuthenticodeSignature|(?m)^\s*exit\b|\$env:[A-Za-z_]*(CONVITE|CREDENCIAL)')
  }
  Write-Host '2. chaves fixadas no install.ps1 iguais byte a byte as do app'
  if ($ChavesApp) {
    $doScript = $UTF8.GetBytes($CHAVES_REAIS + "`n")
    $doApp = [IO.File]::ReadAllBytes($ChavesApp)
    Confere 'igual a app-trusted-keys.json' ([Convert]::ToBase64String($doScript) -ceq [Convert]::ToBase64String($doApp))
  } else { Confere 'app-trusted-keys.json informado (-ChavesApp)' $false }

  $tempos = New-Object System.Collections.Generic.List[long]
  Write-Host '3. os 11 vetores do app (vetores-manifesto.json)'
  if ($Vetores) {
    $v = [IO.File]::ReadAllText($Vetores, $UTF8) | ConvertFrom-Json
    $chavesGerais = [string](Tsa-Canonico ((Ler-JsonEstrito ($v.chaves_confiaveis | ConvertTo-Json -Compress) $false).v))
    $n = 0
    foreach ($x in $v.vetores) {
      $n++
      # O texto do manifesto sai dos bytes canonicos do vetor (sem assinatura) mais a assinatura.
      $can = $UTF8.GetString([Convert]::FromBase64String($x.canonico_b64))
      $mt = $can.Substring(0, $can.Length - 1) + ',"assinatura":"' + $x.manifesto.assinatura + '"}'
      $canonicoIgual = $true
      if ($x.PSObject.Properties['manifesto_texto']) { $mt = [string]$x.manifesto_texto }
      else {
        # O JSON canonico e o hash calculados aqui sao os do app, byte a byte.
        $meu = [string](Tsa-Canonico ((Ler-JsonEstrito $can $false).v))
        $canonicoIgual = ($meu -ceq $can -and (Tsa-Sha256Hex ($UTF8.GetBytes($meu))) -ceq $x.hash)
      }
      $chaves = $chavesGerais
      if ($x.PSObject.Properties['chaves_confiaveis']) { $chaves = ($x.chaves_confiaveis | ConvertTo-Json -Compress) }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $r = Tsa-Verificar $mt $chaves
      $tempos.Add($sw.ElapsedMilliseconds)
      $certo = ($r.ok -eq [bool]$x.esperado.ok)
      if ($x.esperado.PSObject.Properties['motivo']) { $certo = $certo -and ($r['motivo'] -ceq $x.esperado.motivo) }
      if ($x.esperado.PSObject.Properties['campo']) { $certo = $certo -and ($r['campo'] -ceq $x.esperado.campo) }
      if ($x.esperado.ok) { $certo = $certo -and ($r['hash'] -ceq $x.hash) }
      $certo = $certo -and $canonicoIgual
      Confere ("vetor {0}: {1} {2} ({3} ms)" -f $x.nome, $r.ok, $r['motivo'], $sw.ElapsedMilliseconds) $certo
    }
    Confere 'sao 11 vetores' ($n -eq 11)
  } else { Confere 'vetores-manifesto.json informado (-Vetores)' $false }

  Write-Host '4. manifesto real de 02/10/2026 com as chaves reais do script'
  $real = [IO.File]::ReadAllText($REAL, $UTF8)
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Tsa-Verificar $real $CHAVES_REAIS; $tempos.Add($sw.ElapsedMilliseconds)
  Confere "aceito, com o hash que o publicar-na-central assinou ($($sw.ElapsedMilliseconds) ms)" `
    ($r.ok -eq $true -and $r['hash'] -ceq 'b45eae07d968b40e92729e05d378e66ccefc39147b7b54269939d4251275d35f' -and $r['key_id'] -ceq 'tsa-cadu-app-release-v1')
  $r = Tsa-Verificar ($real.Replace('"notas": ""', '"notas": "x"')) $CHAVES_REAIS
  Confere 'com um caractere a mais em notas: assinatura_invalida' ($r.ok -eq $false -and $r['motivo'] -ceq 'assinatura_invalida')
  $r = Tsa-Verificar $real (Chaves-De-Teste)
  Confere 'com a chave errada: chave_desconhecida' ($r.ok -eq $false -and $r['motivo'] -ceq 'chave_desconhecida')

  Write-Host '5. manifesto win32 + x64 e leitura estrita'
  $sha = ('ab' * 32)
  $win = Novo-Manifesto $sha 5000
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Tsa-Verificar $win (Chaves-De-Teste); $tempos.Add($sw.ElapsedMilliseconds)
  Confere 'win32 + x64 com tsa-windows-x64.exe: aceito' ($r.ok -eq $true)
  $r = Tsa-Verificar (Novo-Manifesto $sha 5000 @{ 'artefato.nome' = 'tsa-macos-arm64.dmg' }) (Chaves-De-Teste)
  Confere 'win32 com nome de DMG: manifesto_invalido em artefato.nome' ($r['motivo'] -ceq 'manifesto_invalido' -and $r['campo'] -ceq 'artefato.nome')
  $r = Tsa-Verificar (Novo-Manifesto $sha 5000 @{ arquitetura = 'arm64' }) (Chaves-De-Teste)
  Confere 'win32 + arm64: manifesto_invalido em arquitetura' ($r['motivo'] -ceq 'manifesto_invalido' -and $r['campo'] -ceq 'arquitetura')
  $r = Tsa-Verificar ($win.Replace('"notas":""', '"notas":"x"')) (Chaves-De-Teste)
  Confere 'adulterado depois de assinar: assinatura_invalida' ($r['motivo'] -ceq 'assinatura_invalida')
  foreach ($par in @(
      @('chave repetida', $win.Replace('{"app_id":', '{"schema":"tsa.app.release/v0","app_id":')),
      @('bytes com ponto', $win.Replace('"bytes":5000', '"bytes":5000.0')),
      @('bytes com expoente', $win.Replace('"bytes":5000', '"bytes":5e3')),
      @('bytes com zero a esquerda', $win.Replace('"bytes":5000', '"bytes":05000')),
      @('bytes negativo', $win.Replace('"bytes":5000', '"bytes":-5000')),
      @('campo null', $win.Replace('"notas":""', '"notas":null')),
      @('campo lista', $win.Replace('"notas":""', '"notas":[]')),
      @('campo booleano', $win.Replace('"notas":""', '"notas":true')),
      @('campo a mais', $win.Replace('{"app_id":', '{"a_mais":"x","app_id":')),
      @('lixo depois do fim', ($win + 'x')),
      @('versao com quebra de linha no fim', $win.Replace('"versao":"0.5.0"', '"versao":"0.5.0\n"')),
      @('plataforma em maiuscula', $win.Replace('"plataforma":"win32"', '"plataforma":"WIN32"')),
      @('digito de outro alfabeto na versao', $win.Replace('"versao":"0.5.0"', '"versao":"0.5.٠"')))) {
    $r = Tsa-Verificar $par[1] (Chaves-De-Teste)
    Confere "$($par[0]): manifesto_invalido" ($r.ok -eq $false -and $r['motivo'] -ceq 'manifesto_invalido')
  }
  $assinatura = ([regex]::Match($win, '"assinatura":"([^"]+)"')).Groups[1].Value
  $r = Tsa-Verificar ($win.Replace($assinatura, ('A' * 86) + '==')) (Chaves-De-Teste)
  Confere 'assinatura de zeros: assinatura_invalida' ($r.ok -eq $false -and $r['motivo'] -ceq 'assinatura_invalida')
  $r = Tsa-Verificar $win '{"tsa-teste-f4":"nao e pem"}'
  Confere 'arquivo de chaves irregular: chave_desconhecida' ($r.ok -eq $false -and $r['motivo'] -ceq 'chave_desconhecida')
  $max = ($tempos | Measure-Object -Maximum).Maximum
  Confere "tempo de uma verificacao: maximo $max ms em $($tempos.Count) medidas (limite 60000 ms)" ($max -lt 60000)
}

# ---------------------------------------------------------------- instalador falso
# Aceita /S /D=<pasta> (ultimo argumento, sem aspas), como o NSIS. O modo vem de TSA_FAKE_MODO.
function Compilar-Falso([string]$destino) {
  Add-Type -Language CSharp -OutputType WindowsApplication -OutputAssembly $destino -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
static class InstaladorFalso {
  static void Log(string s) {
    string reg = Environment.GetEnvironmentVariable("TSA_FAKE_LOG");
    if (!string.IsNullOrEmpty(reg)) { try { File.AppendAllText(reg, s + "\r\n"); } catch (Exception) { } }
  }
  static int Main() {
    string cl = Environment.CommandLine;
    string eu = Process.GetCurrentProcess().MainModule.FileName;
    string nome = Path.GetFileName(eu);
    int pid = Process.GetCurrentProcess().Id;
    string modo = Environment.GetEnvironmentVariable("TSA_FAKE_MODO") ?? "ok";
    if (cl.EndsWith(" /filho", StringComparison.Ordinal)) { Log("filho pid=" + pid); Thread.Sleep(600000); return 0; }
    if (string.Equals(nome, "Uninstall TSA.exe", StringComparison.OrdinalIgnoreCase)) {
      Log("desinstalar pid=" + pid + " " + cl);
      string d = Path.GetDirectoryName(eu);
      try { Directory.Delete(Path.Combine(d, "resources"), true); } catch (Exception) { }
      try { File.Delete(Path.Combine(d, "TSA.exe")); } catch (Exception) { }
      return 0;
    }
    if (string.Equals(nome, "TSA.exe", StringComparison.OrdinalIgnoreCase)) { Log("abrir pid=" + pid); return 0; }
    int i = cl.IndexOf(" /D=", StringComparison.Ordinal);
    if (cl.IndexOf(" /S ", StringComparison.Ordinal) < 0 || i < 0) { Log("sem /S /D= :" + cl); return 2; }
    string dest = cl.Substring(i + 4);
    Log("instalar pid=" + pid + " modo=" + modo + " destino=" + dest);
    if (modo == "falha") return 3;
    if (modo == "filho") {
      ProcessStartInfo psi = new ProcessStartInfo(eu, "/filho");
      psi.UseShellExecute = false;
      Process.Start(psi);
      Thread.Sleep(600000);
    }
    Directory.CreateDirectory(Path.Combine(dest, "resources", "tsa"));
    if (modo != "sem-exe") File.Copy(eu, Path.Combine(dest, "TSA.exe"), true);
    File.Copy(eu, Path.Combine(dest, "Uninstall TSA.exe"), true);
    string build = Environment.GetEnvironmentVariable("TSA_FAKE_BUILD") ?? "";
    File.WriteAllText(Path.Combine(dest, "resources", "tsa", "tsa-version.json"), "{\"tsa\":\"0.5.0\",\"build_id\":\"" + build + "\"}\n");
    return 0;
  }
}
'@
}

function Pid-Vivo([int]$p) { return ($null -ne (Get-Process -Id $p -ErrorAction SilentlyContinue)) }
function Pids-Do-Log([string]$log) {
  if (-not (Test-Path -LiteralPath $log)) { return @() }
  return @([regex]::Matches([IO.File]::ReadAllText($log), '(instalar|filho) pid=([0-9]+)') | ForEach-Object { [int]$_.Groups[2].Value })
}

# ---------------------------------------------------------------- preparo comum dos casos
if (Test-Path -LiteralPath $TRAB) { Remove-Item -LiteralPath $TRAB -Recurse -Force }
[void][IO.Directory]::CreateDirectory($TRAB)
$NONCE = [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText((Join-Path $TRAB 'nonce.txt'), $NONCE)
[IO.File]::WriteAllText((Join-Path $TRAB 'inicio.txt'), [DateTime]::Now.AddSeconds(-5).ToString('o'))
$CONVITE = Derivar $NONCE 'convite'
$CRED = Derivar $NONCE 'credencial'
Write-Host ('MARCA-' + $NONCE)
$CHAVES_TESTE = Chaves-De-Teste
$SRV = Join-Path $TRAB 'central'
[void][IO.Directory]::CreateDirectory($SRV)
$S = ''; $LOCAL = ''; $APP = ''; $TSAL = ''; $CFG = @{}; $OUT = ''; $RC = 0
$Fila = New-Object System.Collections.Queue
$Ajustes = @{}
$AoPegarTrava = $null
$Perguntas = New-Object System.Collections.Generic.List[string]

# Trocas do teste sobre o script carregado: Central falsa, chave de teste e respostas da pessoa.
$NovoEstadoOriginal = ${function:Novo-Estado}
function Novo-Estado {
  $e = & $NovoEstadoOriginal
  $e.PainelApi = "http://localhost:$Porta/apptsa/api"
  $e.ReApi = '\Ahttp://localhost:[0-9]+/inteligencia\z'
  $e.PularFerramentas = $true
  $e.EsperaDownloadS = 0
  foreach ($k in @($script:Ajustes.Keys)) { $e[$k] = $script:Ajustes[$k] }
  return $e
}
function Chaves-Confiaveis { return $script:CHAVES_TESTE }
function Read-Host {
  param([switch]$AsSecureString, [Parameter(Position = 0)][string]$Prompt = '')
  $script:Perguntas.Add($Prompt)
  if ($script:Fila.Count -eq 0) { throw 'teste: pergunta sem resposta na fila' }
  $x = [string]$script:Fila.Dequeue()
  if ($AsSecureString) {
    $s = New-Object System.Security.SecureString
    foreach ($c in $x.ToCharArray()) { $s.AppendChar($c) }
    return $s
  }
  return $x
}
$PegarTravaOriginal = ${function:Pegar-Trava}
function Pegar-Trava {
  $r = & $PegarTravaOriginal
  if ($null -ne $script:AoPegarTrava) { & $script:AoPegarTrava | Out-Null }
  return $r
}
if ($SemAmbiente) { function Conferir-Ambiente { } }

function Subir-Central {
  $script:CENTRAL_PROC = Start-Process -FilePath (Caminho-PowerShell) -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$CENTRAL`"", '-Porta', $Porta, '-Pasta', "`"$SRV`"")
  for ($i = 0; $i -lt 100; $i++) {
    try { $r = [Net.WebRequest]::Create("http://localhost:$Porta/saude").GetResponse(); $r.Close(); return } catch { Start-Sleep -Milliseconds 200 }
  }
  throw 'a Central falsa nao subiu'
}
function Parar-Central {
  try { $r = [Net.WebRequest]::Create("http://localhost:$Porta/parar").GetResponse(); $r.Close() } catch { }
  try { if (-not $script:CENTRAL_PROC.WaitForExit(3000)) { $script:CENTRAL_PROC.Kill() } } catch { }
}

function Preparar([string]$nome, [string[]]$com = @()) {
  $script:S = Join-Path $TRAB "c-$nome"
  # Nome de usuario com espaco e acento no caminho.
  $script:LOCAL = Join-Path $script:S ('Usu' + [char]0xE1 + 'rio Jos' + [char]0xE9 + ' Teste\AppData\Local')
  $script:APP = Join-Path $script:LOCAL 'Programs\TSA'
  $script:TSAL = Join-Path $script:LOCAL 'TSA'
  [void][IO.Directory]::CreateDirectory($script:LOCAL)
  Limpar-Cred
  $script:AoPegarTrava = $null
  foreach ($x in $com) {
    if ($x -eq 'app') { [void][IO.Directory]::CreateDirectory($script:APP); [IO.File]::WriteAllText((Join-Path $script:APP 'TSA.exe'), 'velho') }
    if ($x -eq 'cadastrada') {
      [void][IO.Directory]::CreateDirectory((Join-Path $script:TSAL 'atualizador'))
      [IO.File]::WriteAllText((Join-Path $script:TSAL 'atualizador\instalacao.json'), "{ `"installation_id`": `"$UUID`", `"api`": `"http://localhost:$Porta/inteligencia`" }`n", $UTF8)
      [TsaTesteCred]::Gravar("tsa-atualizador:$UUID", $UUID, $CRED)
    }
    if ($x -eq 'perfil') { [void][IO.Directory]::CreateDirectory($script:TSAL); [IO.File]::WriteAllText((Join-Path $script:TSAL 'perfil.json'), "{ `"perfil`": `"gestao`" }`n", $UTF8) }
    if ($x -eq 'atualizador') {
      [void][IO.Directory]::CreateDirectory((Join-Path $script:TSAL 'atualizador'))
      # Atualizador falso: registra a opcao; no -Retomar conclui a troca; no -Agora grava o resumo.
      [IO.File]::WriteAllText((Join-Path $script:TSAL 'atualizador\atualizar.ps1'), @'
param([switch]$Agora, [switch]$Retomar, [switch]$Agendado)
$raiz = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
[IO.File]::AppendAllText((Join-Path $raiz 'atualizador-falso.log'), "Agora=$Agora Retomar=$Retomar politica=$env:PSExecutionPolicyPreference`r`n")
if ($Retomar) {
  if ($env:FAKE_RETOMAR -eq 'falha') { exit 0 }
  if ($env:FAKE_RETOMAR -eq 'ilegivel') { [IO.File]::WriteAllText((Join-Path $raiz 'atualizacao\estado.json'), '{"troca":'); exit 0 }
  [IO.File]::WriteAllText((Join-Path $raiz 'atualizacao\estado.json'), '{"troca":null,"pedidos_tratados":[]}')
  exit 0
}
if ($Agora) {
  if ($env:FAKE_AGORA_RC) { exit [int]$env:FAKE_AGORA_RC }
  if ($env:FAKE_SEM_RESUMO) { exit 0 }
  [void][IO.Directory]::CreateDirectory((Join-Path $raiz 'logs'))
  [IO.File]::WriteAllText((Join-Path $raiz 'logs\atualizar-auto-ultimo.json'), '{"schema":"tsa.atualizacao.resumo/v1","estado":"sem_novidade"}')
}
exit 0
'@)
    }
    if ($x -eq 'troca') {
      [void][IO.Directory]::CreateDirectory((Join-Path $script:TSAL 'atualizacao'))
      [IO.File]::WriteAllText((Join-Path $script:TSAL 'atualizacao\estado.json'), '{"schema":"tsa.atualizacao.estado/v1","estado":"trocando","troca":{"tentativa_id":"6f1c2b9e-1111-4222-8333-944455556666","terminais":[]},"pedidos_tratados":["a","b"]}', $UTF8)
    }
    if ($x -eq 'marca') {
      [void][IO.Directory]::CreateDirectory((Join-Path $script:TSAL 'atualizador'))
      [IO.File]::WriteAllText((Join-Path $script:TSAL 'atualizador\primeira-instalacao.json'), '{ "schema": "tsa.instalacao.primeira/v1", "sha256": "' + $FAKE_SHA + '", "iniciada_em": "2026-10-06T12:00:00Z" }', $UTF8)
      [void][IO.Directory]::CreateDirectory((Join-Path $script:APP 'resources\tsa'))
      [IO.File]::Copy($FAKE_EXE, (Join-Path $script:APP 'Uninstall TSA.exe'))
      [IO.File]::WriteAllText((Join-Path $script:APP 'resto.bin'), 'pela metade')
    }
  }
  $script:CFG = @{ id = "$nome-" + [guid]::NewGuid().ToString('N'); validar = @(200); erro410 = 'convite_usado'; release = 200
    manifesto = $MAN_OK; manifesto2 = ''; artefato = $FAKE_EXE; corte = $false; artefato_codigo = 200; perfil_sugerido = ''; prereqs = '' }
}

function Rodar {
  param([string[]]$Entradas = @(), [string]$Perfil = '', [bool]$SemAgendador = $false, [hashtable]$Ajustes = @{}, [hashtable]$Amb = @{})
  [IO.File]::WriteAllText((Join-Path $SRV 'cfg.json'), ($script:CFG | ConvertTo-Json -Compress), $UTF8)
  $script:Fila = New-Object System.Collections.Queue
  foreach ($e in $Entradas) { $script:Fila.Enqueue($e) }
  $script:Perguntas = New-Object System.Collections.Generic.List[string]
  $script:Ajustes = $Ajustes
  $ambiente = @{ LOCALAPPDATA = $script:LOCAL; TSA_FAKE_LOG = (Join-Path $script:S 'falso.log'); TSA_FAKE_BUILD = $BUILD; TSA_FAKE_MODO = 'ok' }
  foreach ($k in $Amb.Keys) { $ambiente[$k] = $Amb[$k] }
  $antes = @{}
  foreach ($k in $ambiente.Keys) { $antes[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$ambiente[$k]) }
  $global:LASTEXITCODE = 99
  try { $script:OUT = (Main -Perfil $Perfil -SemAgendador $SemAgendador *>&1 | Out-String -Width 4096) }
  finally { foreach ($k in $antes.Keys) { [Environment]::SetEnvironmentVariable($k, $antes[$k]) } }
  $script:RC = $global:LASTEXITCODE
  [IO.File]::AppendAllText((Join-Path $script:S 'saida.txt'), $script:OUT, $UTF8)
}
function Pedidos([string]$rota = '') {
  $log = Join-Path $SRV 'log.jsonl'
  if (-not (Test-Path -LiteralPath $log)) { return @() }
  return @([IO.File]::ReadAllLines($log, $UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } |
      Where-Object { $_.id -eq $script:CFG.id -and ($rota -eq '' -or $_.caminho -like "*$rota*") })
}
function Tem([string]$trecho) { return $script:OUT.Contains($trecho) }
function Instalado { return ((Test-Path -LiteralPath (Join-Path $script:APP 'TSA.exe')) -and ((Ler-JsonArquivo (Join-Path $script:APP 'resources\tsa\tsa-version.json'))['build_id'] -ceq $BUILD)) }
function Nada-Instalado { return (-not (Test-Path -LiteralPath $script:APP)) }
function Sem-Marca { return (-not (Test-Path -LiteralPath (Join-Path $script:TSAL 'atualizador\primeira-instalacao.json'))) }
function Sem-Tmp { return (-not (Test-Path -LiteralPath (Join-Path $script:TSAL 'tmp'))) }
function Baixou { return (@(Pedidos '/artefatos/').Count -gt 0) }
function Retrato([string]$pasta) {
  return ((Get-ChildItem -LiteralPath $pasta -Recurse -Force | Where-Object { $_.Name -ne '.atualizar.trava' } | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName } else { $_.FullName + ' ' + (Sha256Arquivo $_.FullName) } }) -join "`n")
}
function Texto-Falso { $p = Join-Path $script:S 'falso.log'; if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) }; return '' }

# ---------------------------------------------------------------- modos
if ($Modo -eq 'verificador') {
  Testar-Verificador
  Write-Host ''; Write-Host "$PASSOU ok, $FALHOU falhas"
  if ($FALHOU -gt 0) { exit 1 }; exit 0
}

$FAKE_EXE = Join-Path $TRAB 'instalador-falso.exe'
Compilar-Falso $FAKE_EXE
$FAKE_SHA = Sha256Arquivo $FAKE_EXE
$FAKE_BYTES = (Get-Item -LiteralPath $FAKE_EXE).Length
$MAN_OK = Join-Path $TRAB 'manifesto-ok.json'
[IO.File]::WriteAllText($MAN_OK, (Novo-Manifesto $FAKE_SHA $FAKE_BYTES), $UTF8)

if ($Modo -eq 'nsis') {
  # Secao 5.4, item 5, com um instalador NSIS de verdade (o conteudo nao e conferido contra manifesto aqui).
  if (-not $Nsis -or -not (Test-Path -LiteralPath $Nsis)) { throw 'informe -Nsis <caminho do instalador NSIS>' }
  Preparar 'nsis'
  $env:LOCALAPPDATA = $LOCAL
  $script:I = Novo-Estado
  $pasta = Join-Path $TSAL 'tmp\prova'
  [void][IO.Directory]::CreateDirectory($pasta)
  $exe = Join-Path $pasta 'tsa-windows-x64.exe'
  [IO.File]::Copy($Nsis, $exe)
  $sha = Sha256Arquivo $exe
  Write-Host "instalador: $((Get-Item -LiteralPath $exe).Length) bytes, sha256 $sha"
  Write-Host "destino (com espaco e acento): $APP"
  $aberto = Abrir-Conferido $exe (Get-Item -LiteralPath $exe).Length $sha
  Confere 'arquivo aberto e conferido pelo mesmo identificador' ($null -ne $aberto)
  $recusas = 0
  try { [IO.File]::OpenWrite($exe).Dispose() } catch { $recusas++ }
  try { [IO.File]::Delete($exe); if (Test-Path -LiteralPath $exe) { throw 'continua' } } catch { $recusas++ }
  try { [IO.File]::Move($exe, "$exe.outro") } catch { $recusas++ }
  try { [IO.Directory]::Move($pasta, "$pasta-outra") } catch { $recusas++ }
  Confere '(b) escrever, apagar, renomear o arquivo e renomear a pasta falham com o identificador aberto' ($recusas -eq 4)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = [TsaNativo1]::Executar($aberto.Final, ('/S /D=' + $APP), 600000)
  Write-Host "Executar: estado=$($r[0]) codigo=$($r[1]) em $([int]$sw.Elapsed.TotalSeconds) s"
  Confere '(a) o instalador NSIS rodou com o arquivo aberto so para leitura e saiu com 0' ($r[0] -eq 0 -and $r[1] -eq 0)
  $aberto.Fluxo.Dispose()
  Confere 'TSA.exe no destino pedido por /D=' (Test-Path -LiteralPath (Join-Path $APP 'TSA.exe'))
  $versao = Join-Path $APP 'resources\tsa\tsa-version.json'
  if (Test-Path -LiteralPath $versao) { Write-Host ('tsa-version.json: ' + [IO.File]::ReadAllText($versao).Trim()) } else { Write-Host 'tsa-version.json: ausente' }
  Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.DisplayName -like 'TSA*' } | ForEach-Object { Write-Host "registro: DisplayName='$($_.DisplayName)' chave=$($_.PSChildName) DisplayIcon='$($_.DisplayIcon)' InstallLocation='$($_.InstallLocation)' UninstallString='$($_.UninstallString)'" }
  Confere 'o registro aponta para o destino padrao: nao e caso D' ((Ha-TsaForaDoPadrao) -eq $false)
  Confere 'classificacao com o app instalado e sem cadastro: B2' ((Classificar) -ceq 'B2')
  $zona = $null
  try { $zona = Get-Content -LiteralPath $exe -Stream Zone.Identifier -ErrorAction Stop } catch { }
  Confere 'o arquivo baixado pelo script nao leva a marca de internet' ($null -eq $zona)
  if (Test-Path -LiteralPath (Join-Path $APP 'Uninstall TSA.exe')) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = [TsaNativo1]::Executar((Join-Path $APP 'Uninstall TSA.exe'), ('/S _?=' + $APP), 300000)
    Write-Host "Desinstalador: estado=$($r[0]) codigo=$($r[1]) em $([int]$sw.Elapsed.TotalSeconds) s"
    Confere '(e) o desinstalador com /S _?= roda no lugar, o script espera por ele, e o TSA.exe sai' ($r[0] -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $APP 'TSA.exe')))
    if (Test-Path -LiteralPath $APP) { Write-Host ('sobrou em $APP: ' + ((Get-ChildItem -LiteralPath $APP -Recurse -Force | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')) }
  } else { Confere 'Uninstall TSA.exe existe no destino' $false }
  Write-Host ''; Write-Host "$PASSOU ok, $FALHOU falhas"
  if ($FALHOU -gt 0) { exit 1 }; exit 0
}

if ($Modo -eq 'filho-matar') {
  # Usado pela prova (c): roda o instalador falso e fica esperando; o teste mata este processo.
  $env:TSA_FAKE_MODO = 'filho'
  [void][TsaNativo1]::Executar($env:FAKE_EXE_PAI, ('/S /D=' + (Join-Path $TRAB 'nunca')), 600000)
  exit 0
}

Subir-Central
try {
  if ($Modo -eq 'filho-entrada') {
    # Usado pelo caso "sem console": a entrada padrao deste processo esta redirecionada.
    Preparar 'entrada'
    Rodar
    Write-Host $OUT
    Write-Host "RC=$RC pedidos=$(@(Pedidos).Count) perguntas=$($Perguntas.Count)"
    exit 0
  }

  if ($Modo -eq 'console') {
    # Caminho feliz numa janela de console de verdade: recusas reais, Read-Host -AsSecureString real.
    Preparar 'console'
    [IO.File]::WriteAllText((Join-Path $SRV 'cfg.json'), ($CFG | ConvertTo-Json -Compress), $UTF8)
    $bloco = [regex]::Match($TEXTO, "(?s)function Chaves-Confiaveis \{\n  return @'\n.*?\n'@\n\}")
    if (-not $bloco.Success) { throw 'nao achei o bloco das chaves' }
    $copia = $TEXTO.Replace($bloco.Value, "function Chaves-Confiaveis {`n  return @'`n$CHAVES_TESTE`n'@`n}")
    $copia = $copia.Replace("PainelApi = 'https://ace.caduneiva.com/apptsa/api'", "PainelApi = 'http://localhost:$Porta/apptsa/api'")
    $copia = $copia.Replace('PularFerramentas = $false', 'PularFerramentas = $true')
    $arquivo = Join-Path $S 'copia.txt'
    [IO.File]::WriteAllText($arquivo, $copia, $UTF8)
    $rcArquivo = Join-Path $S 'rc.txt'
    $comando = "`$env:LOCALAPPDATA = '$LOCAL'; `$env:TSA_FAKE_LOG = '$(Join-Path $S 'falso.log')'; `$env:TSA_FAKE_BUILD = '$BUILD'; " +
      "Write-Host 'MARCA-$NONCE'; iex ([IO.File]::ReadAllText('$arquivo', [Text.Encoding]::UTF8)); [IO.File]::WriteAllText('$rcArquivo', [string]`$LASTEXITCODE); Start-Sleep 3"
    $janela = Start-Process -FilePath (Caminho-PowerShell) -PassThru -ArgumentList @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($comando)))
    # As teclas entram direto na fila de entrada do console da janela (WriteConsoleInput), por um
    # processo ajudante que se liga a esse console. O ajudante recebe so o numero sorteado e deriva
    # o convite; o convite nao vai em argumento.
    $ajudante = @'
param([int]$Alvo, [string]$Nonce, [string]$Fixo)
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TsaTeclas {
  [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
  struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public int bKeyDown; [FieldOffset(8)] public ushort wRepeatCount;
    [FieldOffset(10)] public ushort wVirtualKeyCode; [FieldOffset(12)] public ushort wVirtualScanCode; [FieldOffset(14)] public char UnicodeChar;
    [FieldOffset(16)] public uint dwControlKeyState;
  }
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] r, uint n, out uint escritos);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static int Digitar(uint pid, string texto) {
    FreeConsole();
    if (!AttachConsole(pid)) return -Marshal.GetLastWin32Error();
    IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) return -1;
    int total = 0;
    foreach (char c in texto) {
      INPUT_RECORD[] r = new INPUT_RECORD[2];
      for (int i = 0; i < 2; i++) { r[i].EventType = 1; r[i].bKeyDown = i == 0 ? 1 : 0; r[i].wRepeatCount = 1; r[i].UnicodeChar = c; r[i].wVirtualKeyCode = (ushort)(c == '\r' ? 0x0D : 0); }
      uint n; if (WriteConsoleInputW(h, r, 2, out n)) total += (int)n;
    }
    CloseHandle(h); FreeConsole();
    return total;
  }
}
"@
$texto = $Fixo
if ($Nonce) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  $texto = [Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Nonce + ':convite'))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
exit [TsaTeclas]::Digitar($Alvo, $texto + "`r")
'@
    $arqAjudante = Join-Path $TRAB 'teclas.ps1'
    [IO.File]::WriteAllText($arqAjudante, $ajudante)
    Start-Sleep -Seconds 12
    $t1 = Start-Process -FilePath (Caminho-PowerShell) -WindowStyle Hidden -PassThru -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$arqAjudante`"", '-Alvo', $janela.Id, '-Nonce', $NONCE)
    for ($i = 0; $i -lt 100 -and @(Pedidos 'convite/validar').Count -eq 0; $i++) { Start-Sleep -Milliseconds 300 }
    Start-Sleep -Seconds 2
    $t2 = Start-Process -FilePath (Caminho-PowerShell) -WindowStyle Hidden -PassThru -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$arqAjudante`"", '-Alvo', $janela.Id, '-Fixo', '1')
    $ativou = ($t1.ExitCode -eq 88 -and $t2.ExitCode -eq 4)
    for ($i = 0; $i -lt 300 -and -not (Test-Path -LiteralPath $rcArquivo); $i++) { Start-Sleep -Milliseconds 300 }
    $rc = ''
    if (Test-Path -LiteralPath $rcArquivo) { $rc = [IO.File]::ReadAllText($rcArquivo) }
    if (-not $janela.WaitForExit(15000)) { try { $janela.Kill() } catch { } }
    Write-Host 'console de verdade: recusas reais, convite digitado no Read-Host -AsSecureString'
    Confere "as teclas entraram no console da janela e o script terminou com 0 (rc='$rc', teclas $($t1.ExitCode) e $($t2.ExitCode))" ($ativou -eq $true -and $rc -ceq '0')
    Confere 'o convite chegou a Central falsa no corpo (validar) e no cabecalho (artefato)' `
      (@(Pedidos 'convite/validar' | Where-Object { $_.corpo_convite -ceq (Sha256Texto $CONVITE) }).Count -eq 1 -and @(Pedidos '/artefatos/' | Where-Object { $_.convite_cabecalho -ceq (Sha256Texto $CONVITE) }).Count -ge 1)
    Confere 'instalou no perfil com espaco e acento e gravou o setor' ((Instalado) -and [IO.File]::ReadAllText((Join-Path $TSAL 'perfil.json')) -ceq "{ `"perfil`": `"trafego`" }`n")
    Confere 'entregou o convite ao Gerenciador de Credenciais' ([TsaTesteCred]::Ler('tsa-convite-pendente') -ceq "convite|1|2|$CONVITE")
    Limpar-Cred
    Write-Host ''; Write-Host "$PASSOU ok, $FALHOU falhas"
    if ($FALHOU -gt 0) { exit 1 }; exit 0
  }

  Testar-Verificador

  # Vigia: guarda a linha de comando de todo processo visto enquanto os casos rodam (T-INS-25).
  $vigiaFim = Join-Path $TRAB 'vigia.fim'
  $vigiaSaida = Join-Path $TRAB 'linhas-de-comando.txt'
  $vigiaCodigo = "`$v = New-Object System.Collections.Generic.HashSet[string]; while (-not (Test-Path -LiteralPath '$vigiaFim')) { foreach (`$p in @(Get-CimInstance Win32_Process)) { if (`$p.CommandLine) { [void]`$v.Add([string]`$p.CommandLine) } }; Start-Sleep -Milliseconds 30 }; [IO.File]::WriteAllLines('$vigiaSaida', @(`$v))"
  $vigia = Start-Process -FilePath (Caminho-PowerShell) -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($vigiaCodigo)))
  Start-Sleep -Seconds 2

  Write-Host '6. caso A: instalacao nova (caminho feliz, com instalador falso)'
  Preparar 'a'
  Rodar -Entradas @($CONVITE, '1')
  Confere 'sai 0' ($RC -eq 0)
  Confere 'instala em %LOCALAPPDATA%\Programs\TSA, num perfil com espaco e acento' (Instalado)
  Confere 'o instalador recebeu /S /D=<pasta> sem aspas, com a pasta inteira' ((Texto-Falso).Contains("modo=ok destino=$APP`r`n"))
  Confere 'grava o setor escolhido, em UTF-8 sem BOM' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $TSAL 'perfil.json'))) -ceq [Convert]::ToBase64String($UTF8.GetBytes("{ `"perfil`": `"trafego`" }`n")))
  Confere 'entrega o convite: tsa-convite-pendente, usuario convite, generica, persistencia local, UTF-16' ([TsaTesteCred]::Ler('tsa-convite-pendente') -ceq "convite|1|2|$CONVITE")
  $val = @(Pedidos 'convite/validar'); $rel = @(Pedidos 'release/nova-instalacao'); $art = @(Pedidos '/artefatos/')
  Confere 'valida o convite no corpo, com application/json' ($val.Count -eq 1 -and $val[0].corpo -ceq '{"convite":"<convite>"}' -and $val[0].corpo_convite -ceq (Sha256Texto $CONVITE) -and $val[0].tipo -like 'application/json*')
  Confere 'pede o manifesto de win32 + x64 e reconsulta antes de instalar' ($rel.Count -eq 2 -and $rel[0].corpo -ceq '{"convite":"<convite>","plataforma":"win32","arquitetura":"x64"}' -and $rel[1].corpo_convite -ceq (Sha256Texto $CONVITE))
  Confere 'baixa pelo SHA-256 do manifesto, com o convite no cabecalho X-TSA-Convite' ($art.Count -eq 1 -and $art[0].caminho -ceq "/apptsa/api/artefatos/$FAKE_SHA" -and $art[0].convite_cabecalho -ceq (Sha256Texto $CONVITE))
  Confere 'o convite nunca vai na URL' (@(Pedidos | Where-Object { ($_.caminho + $_.consulta).Contains($CONVITE) }).Count -eq 0)
  Confere 'apaga a marca de primeira instalacao e a pasta temporaria' ((Sem-Marca) -and (Sem-Tmp))
  Confere 'sem marca sem-agendador; nao grava instalacao.json (quem cadastra e o app)' (-not (Test-Path -LiteralPath (Join-Path $TSAL 'atualizador\sem-agendador')) -and -not (Test-Path -LiteralPath (Join-Path $TSAL 'atualizador\instalacao.json')))
  Confere 'a trava existe e ficou solta' ((Test-Path -LiteralPath (Join-Path $TSAL 'logs\.atualizar.trava')) -and $(try { [IO.File]::Open((Join-Path $TSAL 'logs\.atualizar.trava'), 'Open', 'ReadWrite', 'None').Dispose(); $true } catch { $false }))
  Start-Sleep -Milliseconds 800
  Confere 'abre o TSA e diz que o cadastro termina sozinho' ((Texto-Falso).Contains('abrir pid=') -and (Tem 'terminar o cadastro sozinho'))
  Confere 'mostra o aviso do SmartScreen e nada de erro inesperado' ((Tem 'Executar assim mesmo') -and -not (Tem 'Erro inesperado'))
  Confere 'o convite nao aparece na saida' (-not (Tem $CONVITE))

  Write-Host '7. caso A com -Perfil e -SemAgendador; setor sugerido; -Perfil fora da lista'
  Preparar 'aperfil'
  Rodar -Entradas @($CONVITE) -Perfil 'gestao' -SemAgendador $true
  Confere 'sai 0 sem perguntar o setor' ($RC -eq 0 -and $Perguntas.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $TSAL 'perfil.json')).Contains('"gestao"'))
  Confere 'cria a marca sem-agendador' (Test-Path -LiteralPath (Join-Path $TSAL 'atualizador\sem-agendador'))
  Preparar 'asug'; $CFG.perfil_sugerido = 'audiovisual'
  Rodar -Entradas @("  $CONVITE  ", '9', 'x', '3')
  Confere 'convite com espaco nas pontas vale; setor fora da lista pergunta de novo; grava copy-criativos' ($RC -eq 0 -and (Tem 'O Cadu sugeriu: audiovisual') -and (Tem 'de 1 a 5') -and [IO.File]::ReadAllText((Join-Path $TSAL 'perfil.json')).Contains('"copy-criativos"'))
  Preparar 'aperfilruim'
  Rodar -Entradas @($CONVITE) -Perfil 'copy'
  Confere 'recusa o id antigo copy sem chamar a Central nem perguntar' ($RC -eq 1 -and @(Pedidos).Count -eq 0 -and $Perguntas.Count -eq 0 -and (Nada-Instalado))

  Preparar 'aferr'
  $CFG.prereqs = Join-Path $S 'prereqs-falso.ps1'
  [IO.File]::WriteAllText($CFG.prereqs, 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted -Force; [IO.File]::WriteAllText($env:TSA_FAKE_LOG + ".prereqs", "so=$env:TSA_ONLY_PREREQS arquivo=$env:TSA_PREREQS_ARQUIVO")')
  $politica = [string](Get-ExecutionPolicy -Scope CurrentUser)
  Rodar -Entradas @($CONVITE, '1') -Ajustes @{ PularFerramentas = $false; PrereqsUrl = "http://localhost:$Porta/prereqs.ps1" }
  $marcaFerr = Join-Path $S 'falso.log.prereqs'
  Confere 'passo 10: roda o preparo das ferramentas com TSA_ONLY_PREREQS=1, de dentro de tmp, num caminho com acento' ($RC -eq 0 -and (Test-Path -LiteralPath $marcaFerr) -and [IO.File]::ReadAllText($marcaFerr).StartsWith('so=1 arquivo=' + (Join-Path $TSAL 'tmp')))
  Confere 'o preparo nao muda a politica de execucao do usuario; a pasta temporaria sai no fim' ([string](Get-ExecutionPolicy -Scope CurrentUser) -ceq $politica -and (Sem-Tmp) -and $null -eq $env:TSA_PREREQS_ARQUIVO)

  Write-Host '8. convite: formato errado, invalido (401), usado e expirado (410), limite (429)'
  Preparar 'adigita'
  Rodar -Entradas @('curto', $CONVITE, '2')
  Confere 'formato errado pede de novo sem chamar a Central; depois instala' ($RC -eq 0 -and (Tem '43 caracteres') -and @(Pedidos 'convite/validar').Count -eq 1 -and (Instalado))
  Preparar 'a401'; $CFG.validar = @(401)
  Rodar -Entradas @($CONVITE, $CONVITE, $CONVITE)
  Confere 'tres convites nao reconhecidos: para sem baixar' ($RC -eq 1 -and (Tem 'tentativas sem convite') -and -not (Baixou) -and (Nada-Instalado) -and @(Pedidos 'release').Count -eq 0)
  Preparar 'a401depois'; $CFG.validar = @(401, 200)
  Rodar -Entradas @($CONVITE, $CONVITE, '1')
  Confere 'nao reconhecido e depois valido: instala' ($RC -eq 0 -and (Instalado))
  Preparar 'ausado'; $CFG.validar = @(410)
  Rodar -Entradas @($CONVITE)
  Confere 'convite usado: para com a frase, sem baixar' ($RC -eq 1 -and (Tem 'foi usado') -and -not (Baixou) -and (Nada-Instalado))
  Preparar 'aexpirado'; $CFG.validar = @(410); $CFG.erro410 = 'convite_expirado'
  Rodar -Entradas @($CONVITE)
  Confere 'convite expirado: para com a frase, sem baixar' ($RC -eq 1 -and (Tem 'Este convite venceu') -and -not (Baixou) -and (Nada-Instalado))
  Preparar 'a429'; $CFG.validar = @(429)
  Rodar -Entradas @($CONVITE)
  Confere 'limite de tentativas: para' ($RC -eq 1 -and (Tem 'Muitas tentativas') -and (Nada-Instalado))
  Confere 'convite recusado nunca e entregue ao Gerenciador de Credenciais' ($null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))

  Write-Host '9. manifesto: assinatura errada, leitura estrita, outra plataforma, sem versao liberada'
  foreach ($par in @(
      @('adulterado', (Novo-Manifesto $FAKE_SHA $FAKE_BYTES).Replace('"notas":""', '"notas":"x"')),
      @('chave-repetida', (Novo-Manifesto $FAKE_SHA $FAKE_BYTES).Replace('{"app_id":', '{"schema":"tsa.app.release/v0","app_id":')),
      @('bytes-ponto', (Novo-Manifesto $FAKE_SHA $FAKE_BYTES).Replace('"bytes":' + $FAKE_BYTES, '"bytes":' + $FAKE_BYTES + '.0')),
      @('darwin-valido', (Novo-Manifesto $FAKE_SHA $FAKE_BYTES @{ plataforma = 'darwin'; arquitetura = 'arm64'; 'artefato.nome' = 'tsa-macos-arm64.dmg' })),
      @('chave-desconhecida', (Novo-Manifesto $FAKE_SHA $FAKE_BYTES @{ key_id = 'tsa-outra-chave' })))) {
    Preparar "m-$($par[0])"
    $CFG.manifesto = Join-Path $S 'manifesto.json'
    [IO.File]::WriteAllText($CFG.manifesto, $par[1], $UTF8)
    Rodar -Entradas @($CONVITE, '1')
    Confere "$($par[0]): para antes de baixar, nao instala e nao entrega o convite" ($RC -eq 1 -and (Tem 'passou na confer') -and -not (Baixou) -and (Nada-Instalado) -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  }
  Preparar 'a204'; $CFG.release = 204
  Rodar -Entradas @($CONVITE, '1')
  Confere 'sem versao liberada (204): para com a frase, sem baixar' ($RC -eq 1 -and (Tem 'liberada. Fale com o Cadu') -and -not (Baixou) -and (Nada-Instalado))

  Write-Host '10. artefato: SHA-256 diferente, tamanho diferente, download cortado e retomado'
  Preparar 'asha'
  $outro = [IO.File]::ReadAllBytes($FAKE_EXE); $outro[$outro.Length - 1] = [byte]($outro[$outro.Length - 1] -bxor 1)
  $CFG.artefato = Join-Path $S 'outro.bin'; [IO.File]::WriteAllBytes($CFG.artefato, $outro)
  Rodar -Entradas @($CONVITE, '1')
  Confere 'SHA-256 diferente: nao executa nada, apaga o download e nao instala' ($RC -eq 1 -and (Tem 'passou na confer') -and (Nada-Instalado) -and (Sem-Tmp) -and (Texto-Falso) -ceq '' -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  Preparar 'atam'
  $CFG.artefato = Join-Path $S 'curto.bin'; [IO.File]::WriteAllBytes($CFG.artefato, [byte[]]($outro[0..1000]))
  Rodar -Entradas @($CONVITE, '1')
  Confere 'tamanho diferente: nao executa nada e nao instala' ($RC -eq 1 -and (Nada-Instalado) -and (Sem-Tmp) -and (Texto-Falso) -ceq '')
  Preparar 'acorte'; $CFG.corte = $true
  Rodar -Entradas @($CONVITE, '1')
  $art = @(Pedidos '/artefatos/')
  Confere 'download que cai no meio e retomado por Range e instala' ($RC -eq 0 -and (Instalado) -and $art.Count -eq 2 -and $art[1].range -match '^bytes=[1-9][0-9]*-$')
  Preparar 'a404'; $CFG.artefato_codigo = 404
  Rodar -Entradas @($CONVITE, '1')
  Confere 'artefato recusado pela Central: para sem instalar' ($RC -eq 1 -and (Tem 'download') -and (Nada-Instalado) -and (Sem-Tmp))

  Write-Host '11. passo 7: reconsulta, trava, reclassificacao, falha do instalador'
  Preparar 'amuda'
  $CFG.manifesto2 = Join-Path $S 'manifesto-2.json'
  [IO.File]::WriteAllText($CFG.manifesto2, (Novo-Manifesto $FAKE_SHA $FAKE_BYTES @{ build_id = 'abcdef0.20261007T000000Z' }), $UTF8)
  Rodar -Entradas @($CONVITE, '1')
  Confere 'a release muda durante o download: para sem instalar' ($RC -eq 1 -and (Tem 'mudou durante o download') -and (Nada-Instalado) -and (Texto-Falso) -ceq '')
  Preparar 'atrava'
  [void][IO.Directory]::CreateDirectory((Join-Path $TSAL 'logs'))
  $ocupada = [IO.File]::Open((Join-Path $TSAL 'logs\.atualizar.trava'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { Rodar -Entradas @($CONVITE, '1') } finally { $ocupada.Dispose() }
  Confere 'trava ocupada: para sem instalar e sem deixar marca' ($RC -eq 1 -and (Tem 'outra atualiza') -and (Nada-Instalado) -and (Sem-Marca) -and (Texto-Falso) -ceq '')
  Preparar 'areclass'
  $AoPegarTrava = { [void][IO.Directory]::CreateDirectory($script:APP); [IO.File]::WriteAllText((Join-Path $script:APP 'TSA.exe'), 'de outro instalador') }
  Rodar -Entradas @($CONVITE, '1')
  $AoPegarTrava = $null
  Confere 'outro instalador terminou enquanto este baixava: para sem tocar em nada' ($RC -eq 1 -and (Tem 'foi instalado neste computador') -and [IO.File]::ReadAllText((Join-Path $APP 'TSA.exe')) -ceq 'de outro instalador' -and (Sem-Marca) -and (Texto-Falso) -ceq '' -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  Preparar 'afalha'
  Rodar -Entradas @($CONVITE, '1') -Amb @{ TSA_FAKE_MODO = 'falha' }
  Confere 'instalador sai com erro: nada fica, marca apagada, convite nao entregue' ($RC -eq 1 -and (Tem 'passou na confer') -and (Nada-Instalado) -and (Sem-Marca) -and (Sem-Tmp) -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  Preparar 'abuild'
  Rodar -Entradas @($CONVITE, '1') -Amb @{ TSA_FAKE_BUILD = 'abc1234.20200101T000000Z' }
  Confere 'build_id instalado diferente do manifesto: desinstala, apaga a pasta e a marca' ($RC -eq 1 -and (Tem 'passou na confer') -and (Nada-Instalado) -and (Sem-Marca) -and (Texto-Falso).Contains('desinstalar pid=') -and -not (Texto-Falso).Contains('abrir pid='))
  Preparar 'asemexe'
  Rodar -Entradas @($CONVITE, '1') -Amb @{ TSA_FAKE_MODO = 'sem-exe' }
  Confere 'instalador sai com 0 sem TSA.exe: falha, nada fica' ($RC -eq 1 -and (Nada-Instalado) -and (Sem-Marca))
  Preparar 'atempo'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Rodar -Entradas @($CONVITE, '1') -Amb @{ TSA_FAKE_MODO = 'filho' } -Ajustes @{ InstaladorS = 4 }
  $pids = @(Pids-Do-Log (Join-Path $S 'falso.log'))
  Confere "(d) tempo esgotado encerra a arvore inteira (instalador e filho) e desfaz ($([int]$sw.Elapsed.TotalSeconds) s)" ($RC -eq 1 -and $pids.Count -eq 2 -and @($pids | Where-Object { Pid-Vivo $_ }).Count -eq 0 -and (Nada-Instalado) -and (Sem-Marca))

  Write-Host '12. primeira instalacao interrompida (marca presente)'
  Preparar 'amarca' @('marca')
  Rodar -Entradas @($CONVITE, '1')
  Confere 'limpa o que a marca cobre (desinstalador, pasta, marca) e instala de novo' ($RC -eq 0 -and (Instalado) -and (Sem-Marca) -and (Texto-Falso).Contains('desinstalar pid=') -and -not (Test-Path -LiteralPath (Join-Path $APP 'resto.bin')))
  Confere 'o desinstalador e chamado com /S _?=<pasta do app>, ultimo argumento, sem aspas' ((Texto-Falso) -match ('Uninstall TSA\.exe" /S _\?=' + [regex]::Escape($APP) + "`r`n"))
  Preparar 'amarcamudou' @('marca')
  $AoPegarTrava = {
    # A outra execucao terminou enquanto esta esperava a trava: a marca sumiu e ha um TSA de verdade.
    [IO.File]::Delete((Join-Path $script:TSAL 'atualizador\primeira-instalacao.json'))
    [IO.File]::WriteAllText((Join-Path $script:APP 'TSA.exe'), 'de outro instalador')
    $script:AoPegarTrava = $null
  }
  Rodar -Entradas @($CONVITE, '1')
  $AoPegarTrava = $null
  Confere 'marca que some depois da trava: nao apaga nada e reclassifica (B2)' ($RC -eq 0 -and (Tem 'termina o cadastro e passa a se atualizar sozinho') -and [IO.File]::ReadAllText((Join-Path $APP 'TSA.exe')) -ceq 'de outro instalador' -and (Test-Path -LiteralPath (Join-Path $APP 'resto.bin')) -and -not (Texto-Falso).Contains('desinstalar'))
  Preparar 'amarcaorfao' @('marca')
  $velho = Join-Path $TSAL 'tmp\velho'; [void][IO.Directory]::CreateDirectory($velho)
  [IO.File]::Copy($FAKE_EXE, (Join-Path $velho 'tsa-windows-x64.exe'))
  $orfao = Start-Process -FilePath (Join-Path $velho 'tsa-windows-x64.exe') -ArgumentList '/filho' -PassThru
  Start-Sleep -Milliseconds 800
  Rodar -Entradas @($CONVITE, '1')
  Confere 'instalador orfao em tmp\ e encerrado com a trava na mao; depois limpa e instala' ($RC -eq 0 -and -not (Pid-Vivo $orfao.Id) -and (Instalado) -and (Sem-Marca))
  Preparar 'amarcaruim' @('marca')
  [IO.File]::WriteAllText((Join-Path $TSAL 'atualizador\primeira-instalacao.json'), '{}')
  $retrato = Retrato $LOCAL
  Rodar -Entradas @($CONVITE, '1')
  Confere 'marca fora do formato nao autoriza apagar: para sem mexer em nada' ($RC -eq 1 -and (Tem 'Nada foi apagado') -and (Retrato $LOCAL) -ceq $retrato -and (Texto-Falso) -ceq '' -and $Perguntas.Count -eq 0)
  Preparar 'amarcatrava' @('marca')
  [void][IO.Directory]::CreateDirectory((Join-Path $TSAL 'logs'))
  $ocupada = [IO.File]::Open((Join-Path $TSAL 'logs\.atualizar.trava'), 'OpenOrCreate', 'ReadWrite', 'None')
  $retrato = Retrato $LOCAL
  try { Rodar -Entradas @($CONVITE, '1') } finally { $ocupada.Dispose() }
  Confere 'marca presente com a trava ocupada: para sem mexer em nada' ($RC -eq 1 -and (Tem 'outra instala') -and (Retrato $LOCAL) -ceq $retrato -and @(Pedidos).Count -eq 0)

  Write-Host '13. Controle Inteligente de Aplicativos'
  Preparar 'asac'
  function Get-MpComputerStatus { return [pscustomobject]@{ SmartAppControlState = 'On' } }
  Rodar -Entradas @($CONVITE, '1')
  Confere 'ligado: para antes de pedir o convite, sem baixar' ($RC -eq 1 -and (Tem 'Controle Inteligente de Aplicativos ligado') -and $Perguntas.Count -eq 0 -and @(Pedidos).Count -eq 0)
  function Get-MpComputerStatus { return [pscustomobject]@{ SmartAppControlState = 'Eval' } }
  Preparar 'asaceval'
  Rodar -Entradas @($CONVITE, '1')
  Confere 'em avaliacao: avisa e segue' ($RC -eq 0 -and (Tem 'em avalia') -and (Instalado))
  function Get-MpComputerStatus { throw 'sem Defender' }
  Preparar 'asacerro'
  Rodar -Entradas @($CONVITE, '1')
  Confere 'consulta com erro conta como desligado' ($RC -eq 0 -and (Instalado))
  Remove-Item function:Get-MpComputerStatus

  Write-Host '14. caso B2: tem TSA e nao esta cadastrada'
  Preparar 'b2' @('app')
  $retrato = Retrato $LOCAL
  Rodar
  Confere 'sai 0 com a frase do caso B2, sem convite e sem Central' ($RC -eq 0 -and (Tem 'termina o cadastro e passa a se atualizar sozinho') -and $Perguntas.Count -eq 0 -and @(Pedidos).Count -eq 0)
  Confere 'nao muda nenhum arquivo' ((Retrato $LOCAL) -ceq $retrato)

  Write-Host '15. caso B1: cadastrada, com app'
  Preparar 'b1' @('app', 'cadastrada', 'atualizador')
  Rodar -SemAgendador $true
  $logAt = Join-Path $TSAL 'atualizador-falso.log'
  Confere 'roda o atualizador local com -Agora (caminho com espaco e acento), sem convite' ($RC -eq 0 -and [IO.File]::ReadAllText($logAt).Contains('Agora=True Retomar=False politica=Bypass') -and $Perguntas.Count -eq 0 -and @(Pedidos).Count -eq 0)
  Confere 'aplica -SemAgendador e mostra o resultado desta execucao' ((Test-Path -LiteralPath (Join-Path $TSAL 'atualizador\sem-agendador')) -and (Tem 'Resultado: sem_novidade'))
  Rodar
  Confere 'sem a opcao, apaga a marca sem-agendador' ($RC -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $TSAL 'atualizador\sem-agendador')))
  Rodar -Amb @{ FAKE_SEM_RESUMO = '1' }
  Confere 'resumo velho nao vira resultado' ($RC -eq 1 -and (Tem 'deixou o resultado') -and -not (Tem 'Resultado:'))
  Rodar -Amb @{ FAKE_AGORA_RC = '1' }
  Confere 'atualizador com erro: para com o codigo' ($RC -eq 1 -and (Tem 'parou com erro (1)'))
  Preparar 'b1sem' @('app', 'cadastrada')
  Rodar
  Confere 'sem o script do atualizador: pede para abrir o TSA' ($RC -eq 1 -and (Tem 'Abra o TSA uma vez'))

  Write-Host '16. caso C: cadastrada, sem app'
  Preparar 'c' @('cadastrada', 'perfil')
  Rodar
  $rel = @(Pedidos '/v1/app/release'); $art = @(Pedidos '/artefatos/')
  Confere 'sai 0 e reinstala, sem convite' ($RC -eq 0 -and (Instalado) -and $Perguntas.Count -eq 0 -and @(Pedidos 'convite').Count -eq 0)
  Confere 'usa a credencial de atualizacao no cabecalho Authorization, nas duas rotas' ($rel.Count -eq 2 -and $rel[0].consulta -ceq '?plataforma=win32&arquitetura=x64' -and $rel[0].autorizacao -ceq (Sha256Texto $CRED) -and $art.Count -eq 1 -and $art[0].caminho -ceq "/inteligencia/v1/app/artefatos/$FAKE_SHA" -and $art[0].autorizacao -ceq (Sha256Texto $CRED))
  Confere 'preserva o perfil.json e nao entrega convite' ([IO.File]::ReadAllText((Join-Path $TSAL 'perfil.json')).Contains('"gestao"') -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  Confere 'a credencial continua no Gerenciador de Credenciais e nao aparece na saida' ([TsaTesteCred]::Ler("tsa-atualizador:$UUID") -ceq "$UUID|1|2|$CRED" -and -not (Tem $CRED))
  Preparar 'csemperfil' @('cadastrada')
  Rodar -Entradas @('5')
  Confere 'sem perfil.json: pergunta o setor e grava' ($RC -eq 0 -and (Instalado) -and [IO.File]::ReadAllText((Join-Path $TSAL 'perfil.json')).Contains('"gestao"'))
  Preparar 'cruim' @('cadastrada', 'perfil')
  [TsaTesteCred]::Gravar("tsa-atualizador:$UUID", $UUID, "curta`r`nX-Outro: 1")
  Rodar
  Confere 'credencial fora do formato nao e enviada' ($RC -eq 1 -and (Tem 'aceitou o acesso') -and @(Pedidos).Count -eq 0 -and (Nada-Instalado))
  Preparar 'csemcred' @('cadastrada')
  [void][TsaTesteCred]::Apagar("tsa-atualizador:$UUID")
  Rodar -Entradas @($CONVITE, '1')
  Confere 'instalacao.json sem a credencial nao e cadastro: vira caso A' ($RC -eq 0 -and @(Pedidos 'convite/validar').Count -eq 1 -and (Instalado))

  Write-Host '17. caso D: TSA fora do lugar padrao (registro)'
  $chaveD = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\tsa-teste-f4-fora'
  foreach ($par in @(@('sem cadastro', @()), @('cadastrada', @('cadastrada')))) {
    Preparar "d-$($par[1].Count)" $par[1]
    New-Item -Path $chaveD -Force | Out-Null
    Set-ItemProperty -Path $chaveD -Name DisplayName -Value 'TSA 0.4.13'
    Set-ItemProperty -Path $chaveD -Name DisplayIcon -Value ((Join-Path $LOCAL 'Programs\orca\TSA.exe') + ',0')
    $retrato = Retrato $LOCAL
    try { Rodar -Entradas @($CONVITE, '1') } finally { Remove-Item -Path $chaveD -Recurse -Force }
    Confere "$($par[0]): para com a frase, sem convite, sem Central e sem mudar arquivo" ($RC -eq 1 -and (Tem 'fora do lugar') -and $Perguntas.Count -eq 0 -and @(Pedidos).Count -eq 0 -and (Retrato $LOCAL) -ceq $retrato)
  }
  Preparar 'd-padrao'
  New-Item -Path $chaveD -Force | Out-Null
  Set-ItemProperty -Path $chaveD -Name DisplayName -Value 'TSA'
  Set-ItemProperty -Path $chaveD -Name UninstallString -Value ('"' + (Join-Path $APP 'Uninstall TSA.exe') + '" /currentuser')
  try { Rodar -Entradas @($CONVITE, '1') } finally { Remove-Item -Path $chaveD -Recurse -Force }
  Confere 'registro apontando para a pasta padrao sem o app nao e caso D: instala' ($RC -eq 0 -and (Instalado))

  Write-Host '18. troca interrompida antes de classificar'
  Preparar 'troca' @('app', 'cadastrada', 'atualizador', 'troca')
  Rodar
  $t = [IO.File]::ReadAllText((Join-Path $TSAL 'atualizador-falso.log'))
  Confere 'roda -Retomar e segue como B1' ($RC -eq 0 -and $t.Contains('Agora=False Retomar=True') -and $t.Contains('Agora=True Retomar=False'))
  Preparar 'trocafalha' @('cadastrada', 'atualizador', 'troca')
  Rodar -Amb @{ FAKE_RETOMAR = 'falha' }
  Confere 'retomar nao conclui: para; app ausente com troca pendente nao vira caso C' ($RC -eq 1 -and (Tem 'interrompida') -and (Nada-Instalado) -and @(Pedidos).Count -eq 0)
  Preparar 'trocailegivel' @('cadastrada', 'atualizador', 'troca')
  Rodar -Amb @{ FAKE_RETOMAR = 'ilegivel' }
  Confere 'estado ilegivel depois do -Retomar: para' ($RC -eq 1 -and (Tem 'interrompida') -and (Nada-Instalado))
  Preparar 'trocaestranha'
  [void][IO.Directory]::CreateDirectory((Join-Path $TSAL 'atualizacao'))
  foreach ($ruim in @('{"troca":', '{"troca":false}', '{"estado":"sem_novidade"}')) {
    [IO.File]::WriteAllText((Join-Path $TSAL 'atualizacao\estado.json'), $ruim)
    Rodar -Entradas @($CONVITE, '1')
    Confere "estado.json sem troca legivel ($ruim): nao instala por cima" ($RC -eq 1 -and (Tem 'interrompida') -and (Nada-Instalado) -and @(Pedidos).Count -eq 0)
  }
  [IO.File]::WriteAllText((Join-Path $TSAL 'atualizacao\estado.json'), '{"troca":null}')
  Rodar -Entradas @($CONVITE, '1')
  Confere 'estado.json com "troca": null: instala' ($RC -eq 0 -and (Instalado))
  Preparar 'trocasem' @('troca')
  Rodar -Entradas @($CONVITE, '1')
  Confere 'sem o script do atualizador: para sem instalar' ($RC -eq 1 -and (Tem 'interrompida') -and (Nada-Instalado) -and $Perguntas.Count -eq 0)

  Write-Host '19. sem console: entrada padrao redirecionada'
  $vazio = Join-Path $TRAB 'vazio.txt'; [IO.File]::WriteAllText($vazio, '')
  $saidaFilho = Join-Path $TRAB 'filho-entrada.txt'
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$EU`"", '-MaquinaDeTeste', '-Modo', 'filho-entrada', '-Trabalho', "`"$(Join-Path $TRAB 'filho')`"", '-Porta', ($Porta + 1))
  $p = Start-Process -FilePath (Caminho-PowerShell) -ArgumentList $args2 -RedirectStandardInput $vazio -RedirectStandardOutput $saidaFilho -WindowStyle Hidden -PassThru -Wait
  $t = ''
  if (Test-Path -LiteralPath $saidaFilho) { $t = [IO.File]::ReadAllText($saidaFilho) }
  $script:OUT = $t
  Confere 'para com "Rode este comando no Windows PowerShell", sem perguntar e sem chamar a Central' ($t.Contains('Rode este comando no Windows PowerShell') -and $t.Contains('RC=1 pedidos=0 perguntas=0'))

  Write-Host '20. atualizar.ps1 do painel'
  $textoAt = [IO.File]::ReadAllText($ATUALIZAR, $UTF8)
  Preparar 'atu'
  $env:LOCALAPPDATA_ANTES = $env:LOCALAPPDATA; $env:LOCALAPPDATA = $LOCAL
  try {
    $global:LASTEXITCODE = 0
    $script:OUT = (& ([scriptblock]::Create($textoAt)) *>&1 | Out-String -Width 4096)
    Confere 'sem o atualizador local: sai 1 e aponta o install.ps1' ($global:LASTEXITCODE -eq 1 -and (Tem 'apptsa/install.ps1'))
    Preparar 'atu2' @('atualizador')
    $env:LOCALAPPDATA = $LOCAL
    $global:LASTEXITCODE = 99
    $script:OUT = (& ([scriptblock]::Create($textoAt)) *>&1 | Out-String -Width 4096)
    Confere 'com o atualizador local: roda -Agora pela linha da secao 7.1' ($global:LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText((Join-Path $TSAL 'atualizador-falso.log')).Contains('Agora=True Retomar=False politica=Bypass'))
  } finally { $env:LOCALAPPDATA = $env:LOCALAPPDATA_ANTES; Remove-Item Env:\LOCALAPPDATA_ANTES }

  Write-Host '21. secao 5.4: conferir e executar pelo mesmo identificador; objeto de trabalho'
  Preparar 'p54'
  $env:TSA_FAKE_LOG = Join-Path $S 'falso.log'; $env:TSA_FAKE_BUILD = $BUILD; $env:TSA_FAKE_MODO = 'ok'
  $localAntes = $env:LOCALAPPDATA; $env:LOCALAPPDATA = $LOCAL
  $script:I = Novo-Estado
  $pasta = Join-Path $TSAL 'tmp\prova'; [void][IO.Directory]::CreateDirectory($pasta)
  $exe = Join-Path $pasta 'tsa-windows-x64.exe'; [IO.File]::Copy($FAKE_EXE, $exe)
  # Uma juncao no caminho (pasta de tmp\ que aponta para fora) e recusada.
  $fora = Join-Path $S 'fora'; [void][IO.Directory]::CreateDirectory($fora); [IO.File]::Copy($FAKE_EXE, (Join-Path $fora 'tsa-windows-x64.exe'))
  $desvio = Join-Path $TSAL 'tmp\desvio'
  & cmd.exe /c mklink /J "$desvio" "$fora" | Out-Null
  Confere '(b) juncao posta no caminho e recusada' ((Test-Path -LiteralPath (Join-Path $desvio 'tsa-windows-x64.exe')) -and $null -eq (Abrir-Conferido (Join-Path $desvio 'tsa-windows-x64.exe') $FAKE_BYTES $FAKE_SHA))
  & cmd.exe /c rmdir "$desvio" | Out-Null
  Confere 'arquivo fora de %LOCALAPPDATA%\TSA e recusado' ($null -eq (Abrir-Conferido (Join-Path $fora 'tsa-windows-x64.exe') $FAKE_BYTES $FAKE_SHA))
  Confere 'SHA-256 errado: devolve nulo e deixa o arquivo fechado' ($null -eq (Abrir-Conferido $exe $FAKE_BYTES ('0' * 64)) -and $(try { [IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Dispose(); $true } catch { $false }))
  Confere 'tamanho errado: devolve nulo' ($null -eq (Abrir-Conferido $exe ($FAKE_BYTES + 1) $FAKE_SHA))
  $aberto = Abrir-Conferido $exe $FAKE_BYTES $FAKE_SHA
  $recusas = 0
  try { [IO.File]::OpenWrite($exe).Dispose() } catch { $recusas++ }
  try { [IO.File]::Delete($exe); if (Test-Path -LiteralPath $exe) { throw 'continua' } } catch { $recusas++ }
  try { [IO.File]::Move($exe, "$exe.outro") } catch { $recusas++ }
  try { [IO.Directory]::Move($pasta, "$pasta-outra") } catch { $recusas++ }
  Confere '(b) escrever, apagar, renomear o arquivo e renomear a pasta falham com o identificador aberto' ($null -ne $aberto -and $recusas -eq 4)
  $r = [TsaNativo1]::Executar($aberto.Final, ('/S /D=' + (Join-Path $S ('destino com espa' + [char]0xE7 + 'o'))), 30000)
  Confere '(a) o instalador (falso) roda com o arquivo aberto so para leitura e sai com 0' ($r[0] -eq 0 -and $r[1] -eq 0 -and (Test-Path -LiteralPath (Join-Path $S ('destino com espa' + [char]0xE7 + 'o\TSA.exe'))))
  $aberto.Fluxo.Dispose()
  $r = [TsaNativo1]::Executar((Join-Path $S 'nao-existe.exe'), '/S', 5000)
  Confere 'arquivo que nao existe: estado 2, sem excecao' ($r[0] -eq 2)
  $env:LOCALAPPDATA = $localAntes
  # (c) matar o script com o instalador em andamento encerra o instalador e os filhos.
  $trabFilho = Join-Path $TRAB 'matar'
  $logFilho = Join-Path $S 'matar.log'
  $env:TSA_FAKE_LOG = $logFilho; $env:FAKE_EXE_PAI = $FAKE_EXE
  $args3 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$EU`"", '-MaquinaDeTeste', '-Modo', 'filho-matar', '-Trabalho', "`"$trabFilho`"")
  $p = Start-Process -FilePath (Caminho-PowerShell) -ArgumentList $args3 -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 150 -and @(Pids-Do-Log $logFilho).Count -lt 2; $i++) { Start-Sleep -Milliseconds 200 }
  $pids = @(Pids-Do-Log $logFilho)
  $vivosAntes = @($pids | Where-Object { Pid-Vivo $_ }).Count
  Stop-Process -Id $p.Id -Force
  for ($i = 0; $i -lt 50 -and @($pids | Where-Object { Pid-Vivo $_ }).Count -gt 0; $i++) { Start-Sleep -Milliseconds 200 }
  Confere '(c) matar o script encerra o instalador e o filho dele' ($pids.Count -eq 2 -and $vivosAntes -eq 2 -and @($pids | Where-Object { Pid-Vivo $_ }).Count -eq 0)
  Remove-Item Env:\TSA_FAKE_LOG, Env:\TSA_FAKE_BUILD, Env:\TSA_FAKE_MODO, Env:\FAKE_EXE_PAI -ErrorAction SilentlyContinue

  Write-Host '22. Gerenciador de Credenciais (secao 6.2) e segredo fora de argumento, arquivo e saida (T-INS-25)'
  Limpar-Cred
  $seguro = New-Object System.Security.SecureString
  foreach ($c in $CONVITE.ToCharArray()) { $seguro.AppendChar($c) }
  [TsaNativo1]::CredGravar('tsa-convite-pendente', 'convite', $seguro)
  Confere 'gravar, ler e apagar o convite pendente numa conta sem administrador, sem janela' ([TsaTesteCred]::Ler('tsa-convite-pendente') -ceq "convite|1|2|$CONVITE" -and [TsaTesteCred]::Apagar('tsa-convite-pendente') -and $null -eq [TsaTesteCred]::Ler('tsa-convite-pendente'))
  [TsaTesteCred]::Gravar("tsa-atualizador:$UUID", $UUID, $CRED)
  Confere 'a credencial de atualizacao e achada pelo alvo tsa-atualizador:<installation_id>' ([TsaNativo1]::CredExiste("tsa-atualizador:$UUID") -and -not [TsaNativo1]::CredExiste('tsa-atualizador:00000000-0000-4000-8000-000000000000'))
  Limpar-Cred
  $eu = New-Object System.Security.Principal.WindowsPrincipal ([System.Security.Principal.WindowsIdentity]::GetCurrent())
  Write-Host "       conta: $([Environment]::UserName); administrador: $($eu.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)); sessao interativa: $([Environment]::UserInteractive); recusas de ambiente trocadas: $([bool]$SemAmbiente)"
  [IO.File]::WriteAllText($vigiaFim, '')
  [void]$vigia.WaitForExit(20000)
  Parar-Central
  Start-Sleep -Milliseconds 500
  $linhas = 0
  if (Test-Path -LiteralPath $vigiaSaida) { $linhas = @([IO.File]::ReadAllLines($vigiaSaida)).Count }
  $comSegredo = New-Object System.Collections.Generic.List[string]
  $vistos = 0
  foreach ($f in Get-ChildItem -LiteralPath $TRAB -Recurse -File -Force) {
    $vistos++
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if ((Contem-Segredo $b $CONVITE) -or (Contem-Segredo $b $CRED)) { $comSegredo.Add($f.FullName) }
  }
  $script:OUT = ($comSegredo -join "`n")
  Confere "nenhum processo teve convite ou credencial na linha de comando ($linhas linhas de comando vistas)" ($linhas -gt 5 -and $comSegredo.Count -eq 0)
  Confere "nenhum arquivo do teste tem convite ou credencial: saidas, pedidos, temporarios, perfil, marcas ($vistos arquivos)" ($comSegredo.Count -eq 0)
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
  Write-Host "       politicas: transcricao=$((Get-ItemProperty "$pol\Transcription" -ErrorAction SilentlyContinue).EnableTranscripting) blocos=$((Get-ItemProperty "$pol\ScriptBlockLogging" -ErrorAction SilentlyContinue).EnableScriptBlockLogging)"
} finally {
  Limpar-Cred
  Parar-Central
  if ($vigia -and -not $vigia.HasExited) { try { $vigia.Kill() } catch { } }
}

Write-Host ''
Write-Host "$PASSOU ok, $FALHOU falhas"
if ($FALHOU -gt 0) { $FALHAS | ForEach-Object { Write-Host "  falhou: $_" }; exit 1 }
exit 0
