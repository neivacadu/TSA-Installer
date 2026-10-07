# Instalador do TSA pelo painel (Windows) - INSTALAR-F4-WINDOWS-CONTRATO v1.11, seções 4, 5 e 6.
#   irm https://ace.caduneiva.com/apptsa/install.ps1 | iex
# O comando é o mesmo para todos: o convite é pedido aqui (aparecem asteriscos no lugar dele) e
# nunca entra no comando.
# Casos (seção 5.3):
#   A  máquina nova: valida o convite, pergunta o setor, confere a assinatura do manifesto,
#      baixa, confere tamanho e SHA-256, instala, entrega o convite ao app e abre o TSA.
#   B1 já cadastrada, com app: roda o atualizador local com -Agora.
#   B2 com app e sem cadastro: para sem mudar nada.
#   C  cadastrada, sem app: reinstala com a credencial de atualização do Gerenciador de Credenciais.
#   D  TSA instalado fora do lugar padrão: para sem mudar nada.
# Quem cadastra é o app. Este script nunca troca um TSA que já existe.
# Uso avançado: & ([scriptblock]::Create((irm https://ace.caduneiva.com/apptsa/install.ps1))) -Perfil trafego
# Opções: -Perfil <id> (pula a pergunta do setor) e -SemAgendador.
# Roda em Windows PowerShell 5.1, sem administrador. Não muda a política de execução.
# Tudo fica em funções e só roda na chamada de Main, na última linha.
param([string]$Perfil = '', [switch]$SemAgendador)

$TSA_SCRIPT_VERSAO = "2026.10.07.1"

# ---------------------------------------------------------------- estado e mensagens
function Novo-Estado {
  $local = $env:LOCALAPPDATA
  if (-not $local) { $local = [Environment]::GetFolderPath('LocalApplicationData') }
  $app = Join-Path $local 'Programs\TSA'
  $tsal = Join-Path $local 'TSA'
  return @{
    PainelApi = 'https://ace.caduneiva.com/apptsa/api'
    AppId = 'com.trafegosa.orca-tsa'
    PrereqsUrl = 'https://neivacadu.github.io/TSA-Installer/install.ps1'
    ChaveRegistro = '2b019bad-ee4a-5d89-87a5-c147243d5aa1'
    Programas = Join-Path $local 'Programs'
    Local = $local
    App = $app
    AppExe = Join-Path $app 'TSA.exe'
    Desinstalador = Join-Path $app 'Uninstall TSA.exe'
    Tsal = $tsal
    Atualizador = Join-Path $tsal 'atualizador\atualizar.ps1'
    Instalacao = Join-Path $tsal 'atualizador\instalacao.json'
    SemAgendadorMarca = Join-Path $tsal 'atualizador\sem-agendador'
    Primeira = Join-Path $tsal 'atualizador\primeira-instalacao.json'
    Estado = Join-Path $tsal 'atualizacao\estado.json'
    Pendente = Join-Path $tsal 'atualizacao\instalador-pendente.json'
    Baixado = Join-Path $tsal 'atualizacao\baixado'
    PerfilJson = Join-Path $tsal 'perfil.json'
    TmpRaiz = Join-Path $tsal 'tmp'
    Trava = Join-Path $tsal 'logs\.atualizar.trava'
    Resumo = Join-Path $tsal 'logs\atualizar-auto-ultimo.json'
    Perfis = @('trafego', 'audiovisual', 'copy-criativos', 'cs-operacional', 'gestao')
    ReApi = '\Ahttps://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?\z'
    InstaladorS = 600
    SobraS = 30
    EsperaDownloadS = 3
    PularFerramentas = $false
    FraseFalha = 'A versão baixada não passou na conferência. Nada foi instalado. Fale com o Cadu.'
    ConviteNaoEntregue = $false
    RegistroPasta = ''
    InstaladorId = $null
    Parada = ''
    Rc = 1
    Caso = ''
    Perfil = ''
    PerfilSugerido = ''
    SemAgendador = $false
    Convite = $null
    Id = ''
    Api = ''
    M = $null
    Tmp = ''
    ExeAberto = $null
    TravaAberta = $null
  }
}

function Dizer([string]$texto) { Write-Host $texto -ForegroundColor Cyan }
function Feito([string]$texto) { Write-Host "  ok  $texto" -ForegroundColor Green }
# Para o script com uma frase para a pessoa. Nunca usa exit: com irm | iex ele fecharia a janela.
function Parar([string]$texto) {
  $script:I.Parada = $texto
  throw 'tsa-parar'
}

# ---------------------------------------------------------------- leitor estrito de JSON
# Mesmas regras do lerJsonEstrito do manifesto.mjs e do leitor do install.sh: chave repetida,
# fração, expoente, sinal e zero à esquerda reprovam. true, false, null e lista só passam com
# $extras (respostas e arquivos locais); o manifesto nunca os aceita (Json-SemExtras).
# O ConvertFrom-Json não serve para o manifesto: aceita chave repetida e número com ponto.
function Json-Ws($e) {
  $t = $e.t; $i = $e.i
  while ($i -lt $t.Length -and " `t`n`r".IndexOf($t[$i]) -ge 0) { $i++ }
  $e.i = $i
}

function Json-Texto($e) {
  $t = $e.t; $i = $e.i
  if ($i -ge $t.Length -or [int]$t[$i] -ne 34) { throw 'json' }
  $i++
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    if ($i -ge $t.Length) { throw 'json' }
    $c = $t[$i]; $n = [int]$c
    if ($n -eq 34) { $e.i = $i + 1; $e.v = $sb.ToString(); return }
    if ($n -lt 32) { throw 'json' }
    if ($n -ne 92) { [void]$sb.Append($c); $i++; continue }
    if ($i + 1 -ge $t.Length) { throw 'json' }
    $x = [int]$t[$i + 1]
    $i += 2
    if ($x -eq 34) { [void]$sb.Append([char]34) }
    elseif ($x -eq 92) { [void]$sb.Append([char]92) }
    elseif ($x -eq 47) { [void]$sb.Append([char]47) }
    elseif ($x -eq 98) { [void]$sb.Append([char]8) }
    elseif ($x -eq 102) { [void]$sb.Append([char]12) }
    elseif ($x -eq 110) { [void]$sb.Append([char]10) }
    elseif ($x -eq 114) { [void]$sb.Append([char]13) }
    elseif ($x -eq 116) { [void]$sb.Append([char]9) }
    elseif ($x -eq 117) {
      if ($i + 4 -gt $t.Length) { throw 'json' }
      $h = $t.Substring($i, 4)
      if ($h -cnotmatch '\A[0-9a-fA-F]{4}\z') { throw 'json' }
      [void]$sb.Append([char][Convert]::ToInt32($h, 16))
      $i += 4
    }
    else { throw 'json' }
  }
}

function Json-Valor($e) {
  $e.d++
  if ($e.d -gt 32) { throw 'json' }
  Json-Ws $e
  $t = $e.t
  if ($e.i -ge $t.Length) { throw 'json' }
  $n = [int]$t[$e.i]
  if ($n -eq 123) {
    $e.i++
    $o = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    Json-Ws $e
    if ($e.i -lt $t.Length -and [int]$t[$e.i] -eq 125) { $e.i++; $e.v = $o; $e.d--; return }
    while ($true) {
      Json-Ws $e
      Json-Texto $e
      $k = [string]$e.v
      if ($o.Contains($k)) { throw 'json' }
      Json-Ws $e
      if ($e.i -ge $t.Length -or [int]$t[$e.i] -ne 58) { throw 'json' }
      $e.i++
      Json-Valor $e
      $o.Add($k, $e.v)
      Json-Ws $e
      if ($e.i -ge $t.Length) { throw 'json' }
      $c = [int]$t[$e.i]
      if ($c -eq 44) { $e.i++; continue }
      if ($c -eq 125) { $e.i++; $e.v = $o; $e.d--; return }
      throw 'json'
    }
  }
  if ($n -eq 34) { Json-Texto $e; $e.d--; return }
  if ($e.x -and $n -eq 91) {
    $e.i++
    $l = New-Object System.Collections.ArrayList
    Json-Ws $e
    if ($e.i -lt $t.Length -and [int]$t[$e.i] -eq 93) { $e.i++; $e.v = $l; $e.d--; return }
    while ($true) {
      Json-Valor $e
      [void]$l.Add($e.v)
      Json-Ws $e
      if ($e.i -ge $t.Length) { throw 'json' }
      $c = [int]$t[$e.i]
      if ($c -eq 44) { $e.i++; continue }
      if ($c -eq 93) { $e.i++; $e.v = $l; $e.d--; return }
      throw 'json'
    }
  }
  if ($e.x) {
    if ([string]::CompareOrdinal($t, $e.i, 'true', 0, 4) -eq 0) { $e.i += 4; $e.v = $true; $e.d--; return }
    if ([string]::CompareOrdinal($t, $e.i, 'false', 0, 5) -eq 0) { $e.i += 5; $e.v = $false; $e.d--; return }
    if ([string]::CompareOrdinal($t, $e.i, 'null', 0, 4) -eq 0) { $e.i += 4; $e.v = $null; $e.d--; return }
  }
  $j = $e.i
  while ($j -lt $t.Length -and [int]$t[$j] -ge 48 -and [int]$t[$j] -le 57) { $j++ }
  $dig = $t.Substring($e.i, $j - $e.i)
  if ($dig.Length -eq 0) { throw 'json' }
  if ($dig.Length -gt 1 -and [int]$dig[0] -eq 48) { $dig = '0'; $j = $e.i + 1 }
  if ($j -lt $t.Length) {
    $d = [int]$t[$j]
    if ($d -eq 46 -or $d -eq 101 -or $d -eq 69) { throw 'json' }
  }
  if ($dig.Length -gt 16) { throw 'json' }
  $num = [long]::Parse($dig, [Globalization.CultureInfo]::InvariantCulture)
  if ($num -gt 9007199254740991) { throw 'json' }
  $e.i = $j
  $e.v = $num
  $e.d--
}

# Devolve o valor numa caixa (@{ v = ... }): assim lista vazia e null não se perdem na saída.
function Ler-JsonEstrito([string]$texto, [bool]$extras) {
  $e = @{ t = $texto; i = 0; x = $extras; v = $null; d = 0 }
  Json-Valor $e
  Json-Ws $e
  if ($e.i -ne $texto.Length) { throw 'json' }
  return @{ v = $e.v }
}

function Eh-Objeto($v) { return ($v -is [System.Collections.Specialized.OrderedDictionary]) }

# Só objeto, texto e inteiro, em qualquer nível.
function Json-SemExtras($v) {
  if ($v -is [string] -or $v -is [long]) { return $true }
  if (-not (Eh-Objeto $v)) { return $false }
  foreach ($k in @($v.get_Keys())) {
    if (-not (Json-SemExtras $v[[string]$k])) { return $false }
  }
  return $true
}

# Campo de um objeto lido: texto, ou $null se falta ou não é texto.
function Campo-Texto($o, [string]$nome) {
  if (-not (Eh-Objeto $o)) { return $null }
  if (-not $o.Contains($nome)) { return $null }
  $v = $o[$nome]
  if ($v -is [string]) { return $v }
  return $null
}

function Ler-JsonArquivo([string]$caminho) {
  $bytes = [System.IO.File]::ReadAllBytes($caminho)
  $texto = (New-Object System.Text.UTF8Encoding $false, $true).GetString($bytes)
  if ($texto.Length -gt 0 -and [int]$texto[0] -eq 0xFEFF) { $texto = $texto.Substring(1) }
  return (Ler-JsonEstrito $texto $true).v
}

# ---------------------------------------------------------------- verificador (seção 5.2, W10)
# PowerShell puro: System.Numerics.BigInteger e System.Security.Cryptography. Só o modo verificar.
# Chaves confiáveis, iguais byte a byte a tsa-app/resources/tsa/app-trusted-keys.json (o teste
# compara os dois). O script não busca chave em lugar nenhum.
function Chaves-Confiaveis {
  return @'
{
  "tsa-cadu-app-release-v1": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAlERMsGnZR8BgHewu1esGEdYdBB4V256mXQ6VEW5nNZQ=\n-----END PUBLIC KEY-----\n",
  "tsa-cadu-app-release-v2": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAOgeeJOJQF8+rLmKEWNQ77aRx4poq1WyggwfGmsknD/Q=\n-----END PUBLIC KEY-----\n"
}
'@
}

function Tsa-TextoCanonico([string]$s) {
  if ($s -cmatch '[\u0000-\u0009\u000b-\u001f\u007f-\u009f]') { return $false }
  if ($s -cmatch '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]') { return $false }
  return $true
}

function Tsa-Aspas([string]$s) {
  return '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n') + '"'
}

# JSON canônico do contrato F1, seção 2.2: chaves em ordem de código, sem espaço, três escapes.
function Tsa-Canonico($v) {
  if ($v -is [string]) {
    if (-not (Tsa-TextoCanonico $v)) { throw 'texto' }
    return (Tsa-Aspas $v)
  }
  if ($v -is [long]) {
    if ($v -lt 0 -or $v -gt 9007199254740991) { throw 'numero' }
    return $v.ToString([Globalization.CultureInfo]::InvariantCulture)
  }
  if (Eh-Objeto $v) {
    $ks = New-Object 'string[]' ($v.get_Count())
    $v.get_Keys().CopyTo($ks, 0)
    [Array]::Sort($ks, [StringComparer]::Ordinal)
    $partes = New-Object System.Collections.Generic.List[string]
    foreach ($k in $ks) {
      if ($k -cnotmatch '\A[\x20-\x7e]+\z') { throw 'chave' }
      $partes.Add((Tsa-Aspas $k) + ':' + (Tsa-Canonico $v[[string]$k]))
    }
    return '{' + [string]::Join(',', $partes.ToArray()) + '}'
  }
  throw 'tipo'
}

function Tsa-DataHoraExiste([int]$a, [int]$m, [int]$d, [int]$h, [int]$mi, [int]$s) {
  if ($h -gt 23 -or $mi -gt 59 -or $s -gt 59) { return $false }
  if ($m -lt 1 -or $m -gt 12 -or $d -lt 1) { return $false }
  $dias = @(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$m - 1]
  if ($m -eq 2 -and (($a % 4 -eq 0 -and $a % 100 -ne 0) -or $a % 400 -eq 0)) { $dias = 29 }
  return ($d -le $dias)
}

function Tsa-BuildIdValido($v) {
  if (-not ($v -is [string])) { return $false }
  if ($v -cnotmatch '\A[0-9a-f]{7,12}\.([0-9]{8})T([0-9]{6})Z\z') { return $false }
  $d = $Matches[1]; $h = $Matches[2]
  return (Tsa-DataHoraExiste ([int]$d.Substring(0, 4)) ([int]$d.Substring(4, 2)) ([int]$d.Substring(6, 2)) ([int]$h.Substring(0, 2)) ([int]$h.Substring(2, 2)) ([int]$h.Substring(4, 2)))
}

$script:TSA_ALFABETO = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

# Regra de cada campo do manifesto (contrato F1, seção 2.1). Devolve $true só se o valor vale.
function Tsa-Regra([string]$campo, $v) {
  if (-not ($v -is [string])) { return $false }
  switch -CaseSensitive ($campo) {
    'schema' { return ($v -ceq 'tsa.app.release/v1') }
    'produto' { return ($v -ceq 'TSA') }
    'app_id' { return ($v -ceq 'com.trafegosa.orca-tsa') }
    'versao' { return ($v -cmatch '\A(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,5})\z') }
    'build_id' { return (Tsa-BuildIdValido $v) }
    'versao_orca_base' { return ($v.Length -le 60 -and $v -cmatch '\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}(-[0-9A-Za-z.]{1,40})?\z') }
    'plataforma' { return ($v -ceq 'darwin' -or $v -ceq 'win32') }
    'arquitetura' { return ($v -ceq 'arm64' -or $v -ceq 'x64') }
    'dna_embutido' { return ($v -cmatch '\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}\z') }
    'notas' {
      $pares = [regex]::Matches($v, '[\uD800-\uDBFF][\uDC00-\uDFFF]').Count
      return (($v.Length - $pares) -le 500 -and (Tsa-TextoCanonico $v))
    }
    'publicado_em' {
      if ($v -cnotmatch '\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z\z') { return $false }
      return (Tsa-DataHoraExiste ([int]$Matches[1]) ([int]$Matches[2]) ([int]$Matches[3]) ([int]$Matches[4]) ([int]$Matches[5]) ([int]$Matches[6]))
    }
    'key_id' { return ($v -cmatch '\A[a-z0-9][a-z0-9-]{2,62}\z') }
    'assinatura' {
      # Base64 canônico: os bits que sobram no último caractere têm de ser zero.
      if ($v -cnotmatch '\A[A-Za-z0-9+/]{86}==\z') { return $false }
      return (($script:TSA_ALFABETO.IndexOf($v[85]) -band 15) -eq 0)
    }
  }
  return $false
}

# Devolve o nome do primeiro campo irregular, ou '' se o manifesto vale.
function Tsa-Validar($m) {
  $campos = @('schema', 'produto', 'app_id', 'versao', 'build_id', 'versao_orca_base', 'plataforma',
    'arquitetura', 'artefato', 'dna_embutido', 'notas', 'publicado_em', 'key_id', 'assinatura')
  $camposArtefato = @('nome', 'sha256', 'bytes', 'url')
  if (-not (Eh-Objeto $m)) { return '(raiz)' }
  foreach ($k in @($m.get_Keys())) { if ($campos -cnotcontains [string]$k) { return [string]$k } }
  foreach ($c in $campos) {
    if (-not $m.Contains($c)) { return $c }
    if ($c -cne 'artefato' -and (Tsa-Regra $c $m[$c]) -ne $true) { return $c }
  }
  $a = $m['artefato']
  if (-not (Eh-Objeto $a)) { return 'artefato' }
  foreach ($k in @($a.get_Keys())) { if ($camposArtefato -cnotcontains [string]$k) { return 'artefato.' + [string]$k } }
  foreach ($c in $camposArtefato) { if (-not $a.Contains($c)) { return 'artefato.' + $c } }
  $nome = ''
  $par = [string]$m['plataforma'] + '/' + [string]$m['arquitetura']
  if ($par -ceq 'darwin/arm64') { $nome = 'tsa-macos-arm64.dmg' }
  elseif ($par -ceq 'win32/x64') { $nome = 'tsa-windows-x64.exe' }
  if (-not $nome) { return 'arquitetura' }
  if (-not ($a['nome'] -is [string]) -or $a['nome'] -cne $nome) { return 'artefato.nome' }
  if (-not ($a['sha256'] -is [string]) -or $a['sha256'] -cnotmatch '\A[0-9a-f]{64}\z') { return 'artefato.sha256' }
  if (-not ($a['bytes'] -is [long]) -or $a['bytes'] -lt 1 -or $a['bytes'] -gt 629145600) { return 'artefato.bytes' }
  if (-not ($a['url'] -is [string]) -or $a['url'] -cne ('/v1/app/artefatos/' + $a['sha256'])) { return 'artefato.url' }
  return ''
}

function Tsa-Sha256Hex([byte[]]$bytes) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  try { return ([BitConverter]::ToString($h.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
  finally { $h.Dispose() }
}

# Ed25519, RFC 8032 seção 5.1.7: S menor que L; R recalculado como [S]B - [k]A e comparado por bytes.
function Ed-Iniciar {
  if (Get-Variable -Name TSA_ED -Scope Script -ErrorAction SilentlyContinue) { return }
  $n = { param([string]$s) [System.Numerics.BigInteger]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) }
  $p = & $n '57896044618658097711785492504343953926634992332820282019728792003956564819949'
  $bx = & $n '15112221349535400772501151409588531511454012693041857206046113283949847762202'
  $by = & $n '46316835694926478169428394003475163141307993866256225615783033603165251855960'
  $script:TSA_ED = @{
    P = $p
    L = & $n '7237005577332262213973186563042994240857116359379907606001950938285454250989'
    D = & $n '37095705934669439343138083508754565189542113879843219016388785533085940283555'
    D2 = & $n '16295367250680780974490674513165176452449235426866156013048779062215315747161'
    RaizM1 = & $n '19681161376707505956807079304988542015446066515923890162744021073123829784752'
    PM2 = & $n '57896044618658097711785492504343953926634992332820282019728792003956564819947'
    P38 = & $n '7237005577332262213973186563042994240829374041602535252466099000494570602494'
    Um = [System.Numerics.BigInteger]::One
    Dois = & $n '2'
    Base = @($bx, $by, [System.Numerics.BigInteger]::One, [System.Numerics.BigInteger]::Remainder([System.Numerics.BigInteger]::Multiply($bx, $by), $p))
  }
}

function Ed-Mod($a) {
  $r = [System.Numerics.BigInteger]::Remainder($a, $script:TSA_ED.P)
  if ($r.Sign -lt 0) { $r = [System.Numerics.BigInteger]::Add($r, $script:TSA_ED.P) }
  return $r
}

# Inteiro sem sinal a partir de bytes em ordem little-endian.
function Ed-Le([byte[]]$bytes) {
  $b = New-Object 'byte[]' ($bytes.Length + 1)
  [Array]::Copy($bytes, $b, $bytes.Length)
  return (New-Object System.Numerics.BigInteger (, $b))
}

function Ed-Soma($p, $q) {
  $m = $script:TSA_ED.P
  $a = (($p[1] - $p[0]) * ($q[1] - $q[0])) % $m
  $b = (($p[1] + $p[0]) * ($q[1] + $q[0])) % $m
  $c = ($script:TSA_ED.D2 * $p[3] * $q[3]) % $m
  $d = ($script:TSA_ED.Dois * $p[2] * $q[2]) % $m
  $e = $b - $a; $f = $d - $c; $g = $d + $c; $h = $b + $a
  return , @((($e * $f) % $m), (($g * $h) % $m), (($f * $g) % $m), (($e * $h) % $m))
}

function Ed-Vezes($k, $p) {
  $r = @([System.Numerics.BigInteger]::Zero, [System.Numerics.BigInteger]::One, [System.Numerics.BigInteger]::One, [System.Numerics.BigInteger]::Zero)
  foreach ($byte in $k.ToByteArray()) {
    for ($j = 0; $j -lt 8; $j++) {
      if ((([int]$byte) -shr $j) -band 1) { $r = Ed-Soma $r $p }
      $p = Ed-Soma $p $p
    }
  }
  return , $r
}

# Decodifica um ponto (RFC 8032, 5.1.3). Devolve $null se os bytes não são um ponto da curva.
function Ed-Ponto([byte[]]$bytes) {
  if ($bytes.Length -ne 32) { return $null }
  $ed = $script:TSA_ED
  $sinal = ([int]$bytes[31]) -shr 7
  $c = New-Object 'byte[]' 32
  [Array]::Copy($bytes, $c, 32)
  $c[31] = [byte](([int]$c[31]) -band 0x7F)
  $y = Ed-Le $c
  if ($y.CompareTo($ed.P) -ge 0) { return $null }
  $y2 = ($y * $y) % $ed.P
  $u = Ed-Mod ($y2 - $ed.Um)
  $v = Ed-Mod ($ed.D * $y2 + $ed.Um)
  $x2 = Ed-Mod ($u * [System.Numerics.BigInteger]::ModPow($v, $ed.PM2, $ed.P))
  $x = [System.Numerics.BigInteger]::ModPow($x2, $ed.P38, $ed.P)
  if (-not (Ed-Mod ($x * $x - $x2)).IsZero) { $x = ($x * $ed.RaizM1) % $ed.P }
  if (-not (Ed-Mod ($x * $x - $x2)).IsZero) { return $null }
  if ($x.IsZero -and $sinal -eq 1) { return $null }
  if ((-not $x.IsEven) -ne ($sinal -eq 1)) { $x = $ed.P - $x }
  return , @($x, $y, $ed.Um, (($x * $y) % $ed.P))
}

function Ed-Codificar($p) {
  $ed = $script:TSA_ED
  $zi = [System.Numerics.BigInteger]::ModPow((Ed-Mod $p[2]), $ed.PM2, $ed.P)
  $x = Ed-Mod ($p[0] * $zi)
  $y = Ed-Mod ($p[1] * $zi)
  $s = New-Object 'byte[]' 32
  $yb = $y.ToByteArray()
  [Array]::Copy($yb, $s, [Math]::Min(32, $yb.Length))
  if (-not $x.IsEven) { $s[31] = [byte](([int]$s[31]) -bor 0x80) }
  return , $s
}

# Devolve $true só se a assinatura vale. Qualquer outra saída, ou erro, reprova em quem chama.
function Ed-Verificar([byte[]]$chave, [byte[]]$mensagem, [byte[]]$assinatura) {
  Ed-Iniciar
  $ed = $script:TSA_ED
  if ($chave.Length -ne 32 -or $assinatura.Length -ne 64) { return $false }
  $pontoA = Ed-Ponto $chave
  if ($null -eq $pontoA) { return $false }
  # Nomes sem depender de maiúscula: no PowerShell, $s e $S são a mesma variável.
  $bytesS = New-Object 'byte[]' 32
  [Array]::Copy($assinatura, 32, $bytesS, 0, 32)
  $parteS = Ed-Le $bytesS
  if ($parteS.CompareTo($ed.L) -ge 0) { return $false }
  $buf = New-Object 'byte[]' (64 + $mensagem.Length)
  [Array]::Copy($assinatura, 0, $buf, 0, 32)
  [Array]::Copy($chave, 0, $buf, 32, 32)
  [Array]::Copy($mensagem, 0, $buf, 64, $mensagem.Length)
  $sha = New-Object System.Security.Cryptography.SHA512CryptoServiceProvider
  try { $k = [System.Numerics.BigInteger]::Remainder((Ed-Le $sha.ComputeHash($buf)), $ed.L) } finally { $sha.Dispose() }
  $menosA = @((Ed-Mod ([System.Numerics.BigInteger]::Negate($pontoA[0]))), $pontoA[1], $pontoA[2], (Ed-Mod ([System.Numerics.BigInteger]::Negate($pontoA[3]))))
  $pontoS = Ed-Vezes $parteS $ed.Base
  $pontoK = Ed-Vezes $k $menosA
  $calculado = Ed-Codificar (Ed-Soma $pontoS $pontoK)
  if ($calculado.Length -ne 32) { return $false }
  for ($i = 0; $i -lt 32; $i++) { if ($calculado[$i] -ne $assinatura[$i]) { return $false } }
  return $true
}

# PEM SPKI Ed25519 exato (44 bytes DER, prefixo do OID 1.3.101.112), base64 canônico.
function Tsa-ChaveDoPem($pem) {
  if (-not ($pem -is [string])) { return $null }
  if ($pem -cnotmatch '\A-----BEGIN PUBLIC KEY-----\n([A-Za-z0-9+/]{59}=)\n-----END PUBLIC KEY-----\n\z') { return $null }
  $b64 = $Matches[1]
  if (($script:TSA_ALFABETO.IndexOf($b64[58]) -band 3) -ne 0) { return $null }
  $der = [Convert]::FromBase64String($b64)
  if ($der.Length -ne 44) { return $null }
  $prefixo = @(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
  for ($i = 0; $i -lt 12; $i++) { if ($der[$i] -ne $prefixo[$i]) { return $null } }
  $chave = New-Object 'byte[]' 32
  [Array]::Copy($der, 12, $chave, 0, 32)
  return , $chave
}

# O arquivo de chaves inteiro tem de estar no formato; uma entrada irregular reprova todas.
function Tsa-ChaveConfiavel([string]$textoChaves, [string]$keyId) {
  $chaves = (Ler-JsonEstrito $textoChaves $false).v
  if (-not (Eh-Objeto $chaves) -or $chaves.get_Count() -eq 0) { return $null }
  $achada = $null
  foreach ($id in @($chaves.get_Keys())) {
    if ([string]$id -cnotmatch '\A[a-z0-9][a-z0-9-]{2,62}\z') { return $null }
    $c = Tsa-ChaveDoPem $chaves[[string]$id]
    if ($null -eq $c) { return $null }
    if ([string]$id -ceq $keyId) { $achada = $c }
  }
  if ($null -eq $achada) { return $null }
  return , $achada
}

# Verifica um manifesto já lido pelo leitor estrito. Resultado: @{ ok; hash; key_id } ou
# @{ ok = $false; motivo; campo }, com os motivos do contrato (seção 5.2, item 2).
function Tsa-VerificarArvore($m, [string]$textoChaves) {
  $invalido = @{ ok = $false; motivo = 'manifesto_invalido'; campo = '(raiz)' }
  try {
    if (-not (Json-SemExtras $m)) { return $invalido }
    $campo = Tsa-Validar $m
  } catch { return $invalido }
  if (-not ($campo -is [string])) { return $invalido }
  if ($campo -cne '') { return @{ ok = $false; motivo = 'manifesto_invalido'; campo = $campo } }
  $chave = $null
  try { $chave = Tsa-ChaveConfiavel $textoChaves ([string]$m['key_id']) } catch { $chave = $null }
  if (-not ($chave -is [byte[]]) -or $chave.Length -ne 32) { return @{ ok = $false; motivo = 'chave_desconhecida' } }
  $hash = ''
  try {
    $resto = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    foreach ($k in @($m.get_Keys())) { if ([string]$k -cne 'assinatura') { $resto.Add([string]$k, $m[[string]$k]) } }
    $hash = Tsa-Sha256Hex ((New-Object System.Text.UTF8Encoding $false, $true).GetBytes([string](Tsa-Canonico $resto)))
  } catch { return $invalido }
  if (-not ($hash -is [string]) -or $hash -cnotmatch '\A[0-9a-f]{64}\z') { return $invalido }
  $vale = $false
  try {
    $vale = Ed-Verificar $chave ([System.Text.Encoding]::ASCII.GetBytes($hash)) ([Convert]::FromBase64String([string]$m['assinatura']))
  } catch { $vale = $false }
  if (-not ($vale -is [bool]) -or $vale -ne $true) { return @{ ok = $false; motivo = 'assinatura_invalida' } }
  return @{ ok = $true; hash = $hash; key_id = [string]$m['key_id'] }
}

# Modo verificar, a partir do texto do manifesto e do texto do arquivo de chaves.
function Tsa-Verificar([string]$textoManifesto, [string]$textoChaves) {
  $m = $null
  try { $m = (Ler-JsonEstrito $textoManifesto $false).v }
  catch { return @{ ok = $false; motivo = 'manifesto_invalido'; campo = '(raiz)' } }
  return (Tsa-VerificarArvore $m $textoChaves)
}

# ---------------------------------------------------------------- código nativo (Add-Type)
# Gerenciador de Credenciais (seção 6.2), segredo dentro do pedido HTTP (5.1, itens 4 e 6) e
# objeto de trabalho do instalador (5.4, item 3). Nenhum segredo no fonte. O convite só existe
# como SecureString no PowerShell: o texto é aberto aqui, usado e zerado, e nunca volta para o
# PowerShell, para a saída nem para o pipeline.
function Carregar-Nativo {
  if ('TsaNativo2' -as [type]) { return }
  Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Threading;

public static class TsaNativo2 {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL {
    public uint Flags; public uint Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob;
    public uint Persist; public uint AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName;
  }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredWriteW(ref CREDENTIAL c, uint flags);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredReadW(string alvo, uint tipo, uint flags, out IntPtr cred);
  [DllImport("advapi32.dll")]
  static extern void CredFree(IntPtr p);

  const uint CRED_TYPE_GENERIC = 1;
  const uint CRED_PERSIST_LOCAL_MACHINE = 2;

  static char[] Abrir(SecureString s) {
    char[] c = new char[s.Length];
    IntPtr p = Marshal.SecureStringToBSTR(s);
    try { Marshal.Copy(p, c, 0, c.Length); } finally { Marshal.ZeroFreeBSTR(p); }
    return c;
  }
  // Convite e credencial de atualização têm o mesmo formato: 43 caracteres base64url.
  static bool Formato(char[] c) {
    if (c.Length != 43) return false;
    foreach (char x in c) {
      bool ok = (x >= 'A' && x <= 'Z') || (x >= 'a' && x <= 'z') || (x >= '0' && x <= '9') || x == '_' || x == '-';
      if (!ok) return false;
    }
    return true;
  }
  // Tira espaço e quebra de linha das pontas (colar costuma trazer).
  public static SecureString Aparar(SecureString s) {
    char[] c = Abrir(s);
    try {
      int a = 0, b = c.Length;
      while (a < b && char.IsWhiteSpace(c[a])) a++;
      while (b > a && char.IsWhiteSpace(c[b - 1])) b--;
      SecureString r = new SecureString();
      for (int i = a; i < b; i++) r.AppendChar(c[i]);
      r.MakeReadOnly();
      return r;
    } finally { Array.Clear(c, 0, c.Length); }
  }
  public static bool ConviteFormato(SecureString s) {
    char[] c = Abrir(s);
    try { return Formato(c); } finally { Array.Clear(c, 0, c.Length); }
  }
  // Corpo {"convite":"<convite>"<resto>} escrito direto no pedido.
  public static void CorpoConvite(HttpWebRequest req, SecureString s, string resto) {
    char[] c = Abrir(s);
    byte[] corpo = null;
    try {
      if (!Formato(c)) throw new InvalidOperationException("convite fora do formato");
      byte[] a = Encoding.ASCII.GetBytes("{\"convite\":\"");
      byte[] z = Encoding.UTF8.GetBytes("\"" + (resto ?? "") + "}");
      corpo = new byte[a.Length + c.Length + z.Length];
      Buffer.BlockCopy(a, 0, corpo, 0, a.Length);
      for (int i = 0; i < c.Length; i++) corpo[a.Length + i] = (byte)c[i];
      Buffer.BlockCopy(z, 0, corpo, a.Length + c.Length, z.Length);
      req.ContentType = "application/json";
      req.ContentLength = corpo.Length;
      using (Stream st = req.GetRequestStream()) { st.Write(corpo, 0, corpo.Length); }
    } finally {
      Array.Clear(c, 0, c.Length);
      if (corpo != null) Array.Clear(corpo, 0, corpo.Length);
    }
  }
  public static void CabecalhoConvite(HttpWebRequest req, SecureString s) {
    char[] c = Abrir(s);
    try {
      if (!Formato(c)) throw new InvalidOperationException("convite fora do formato");
      req.Headers["X-TSA-Convite"] = new string(c);
    } finally { Array.Clear(c, 0, c.Length); }
  }

  static char[] LerBlob(string alvo) {
    IntPtr p;
    if (!CredReadW(alvo, CRED_TYPE_GENERIC, 0, out p)) return null;
    try {
      CREDENTIAL cr = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      int n = (int)cr.CredentialBlobSize;
      if (cr.CredentialBlob == IntPtr.Zero || n <= 0 || n > 1024 || (n % 2) != 0) return new char[0];
      char[] c = new char[n / 2];
      Marshal.Copy(cr.CredentialBlob, c, 0, c.Length);
      for (int i = 0; i < n; i++) Marshal.WriteByte(cr.CredentialBlob, i, 0);
      return c;
    } finally { CredFree(p); }
  }
  public static bool CredExiste(string alvo) {
    char[] c = LerBlob(alvo);
    if (c == null) return false;
    Array.Clear(c, 0, c.Length);
    return true;
  }
  // Lê a credencial de atualização e a põe no cabeçalho. Fora do formato: não envia nada.
  public static bool CabecalhoCredencial(HttpWebRequest req, string alvo) {
    char[] c = LerBlob(alvo);
    if (c == null) return false;
    try {
      if (!Formato(c)) return false;
      req.Headers["Authorization"] = "Bearer " + new string(c);
      return true;
    } finally { Array.Clear(c, 0, c.Length); }
  }
  public static void CredGravar(string alvo, string usuario, SecureString s) {
    IntPtr p = Marshal.SecureStringToBSTR(s);
    try {
      CREDENTIAL cr = new CREDENTIAL();
      cr.Type = CRED_TYPE_GENERIC;
      cr.TargetName = alvo;
      cr.UserName = usuario;
      cr.CredentialBlob = p;
      cr.CredentialBlobSize = (uint)(s.Length * 2);
      cr.Persist = CRED_PERSIST_LOCAL_MACHINE;
      if (!CredWriteW(ref cr, 0)) throw new InvalidOperationException("CredWrite falhou: " + Marshal.GetLastWin32Error());
    } finally { Marshal.ZeroFreeBSTR(p); }
  }

  // ---- objeto de trabalho
  [StructLayout(LayoutKind.Sequential)]
  struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
    public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)]
  struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io;
    public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
    public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
    public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO {
    public int cb; public IntPtr lpReserved, lpDesktop, lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateJobObjectW(IntPtr attr, string nome);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetInformationJobObject(IntPtr job, int classe, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint tam);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool QueryInformationJobObject(IntPtr job, int classe, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info, uint tam, IntPtr ret);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processo);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool TerminateJobObject(IntPtr job, uint codigo);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcessW(string app, StringBuilder linha, IntPtr pa, IntPtr ta, bool herdar, uint flags,
    IntPtr ambiente, string pasta, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetExitCodeProcess(IntPtr h, out uint codigo);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool TerminateProcess(IntPtr h, uint codigo);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool IsProcessInJob(IntPtr processo, IntPtr job, out bool dentro);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetProcessTimes(IntPtr h, out long criado, out long saiu, out long nucleo, out long usuario);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr SendMessageTimeoutW(IntPtr janela, uint msg, UIntPtr w, string l, uint flags, uint ms, out UIntPtr resultado);
  // Avisa o sistema de que as variáveis de ambiente mudaram (WM_SETTINGCHANGE): janelas novas já enxergam.
  public static void AvisarAmbiente() {
    UIntPtr r;
    SendMessageTimeoutW(new IntPtr(0xffff), 0x001A, UIntPtr.Zero, "Environment", 2, 5000, out r);
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder caminho, uint tam, uint flags);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateFileW(string nome, uint acesso, uint partilha, IntPtr seg, uint criacao, uint flags, IntPtr modelo);

  // Caminho final de um identificador aberto, como o sistema o vê (sem junção nem atalho no meio).
  public static string CaminhoFinal(Microsoft.Win32.SafeHandles.SafeFileHandle h) {
    StringBuilder sb = new StringBuilder(1024);
    uint n = GetFinalPathNameByHandleW(h.DangerousGetHandle(), sb, (uint)sb.Capacity, 0);
    if (n == 0 || n >= sb.Capacity) return null;
    return sb.ToString();
  }
  // Caminho final de uma pasta (aberta só para consulta).
  public static string CaminhoFinalDaPasta(string pasta) {
    IntPtr h = CreateFileW(pasta, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
    if (h == IntPtr.Zero || h == new IntPtr(-1)) return null;
    try {
      StringBuilder sb = new StringBuilder(1024);
      uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
      if (n == 0 || n >= sb.Capacity) return null;
      return sb.ToString();
    } finally { CloseHandle(h); }
  }

  const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
  const uint CREATE_SUSPENDED = 0x4;
  const uint CREATE_UNICODE_ENVIRONMENT = 0x400;

  static uint Ativos(IntPtr job) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION a;
    if (!QueryInformationJobObject(job, 1, out a, (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero)) return 1;
    return a.ActiveProcesses;
  }
  // Roda "<exe>" <argumentos> dentro de um objeto de trabalho que morre com este processo
  // (KILL_ON_JOB_CLOSE, identificador não herdável). Ordem da seção 5.4, item 3: o processo nasce
  // suspenso, entra no objeto, a entrada é conferida e só então ele anda: nenhum filho escapa. Espera o processo e o objeto ficar sem processos; no tempo esgotado encerra
  // a árvore inteira. Não herda identificadores (nem a trava, nem o arquivo conferido).
  // Devolve { estado, código }: estado 0 terminou, 1 tempo esgotado e árvore encerrada, 2 não
  // conseguiu rodar, 3 tempo esgotado sem confirmar que a árvore saiu.
  public static long[] Executar(string exe, string argumentos, int limiteMs) {
    return Executar(exe, argumentos, limiteMs, null);
  }
  // aoCriar recebe o número do processo e a hora de criação (FILETIME, UTC) logo depois de ele
  // nascer suspenso, antes de entrar no objeto e de andar. Se devolve false, o processo é
  // encerrado sem ter rodado.
  public static long[] Executar(string exe, string argumentos, int limiteMs, Func<int, long, bool> aoCriar) {
    IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
    if (job == IntPtr.Zero) return new long[] { 2, Marshal.GetLastWin32Error() };
    try {
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      info.Basic.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
        return new long[] { 2, Marshal.GetLastWin32Error() };
      STARTUPINFO si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      PROCESS_INFORMATION pi;
      StringBuilder linha = new StringBuilder("\"" + exe + "\" " + argumentos);
      if (!CreateProcessW(exe, linha, IntPtr.Zero, IntPtr.Zero, false, CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
          IntPtr.Zero, null, ref si, out pi))
        return new long[] { 2, Marshal.GetLastWin32Error() };
      try {
        if (aoCriar != null) {
          long criado, t2, t3, t4;
          bool registrou = false;
          try { registrou = GetProcessTimes(pi.hProcess, out criado, out t2, out t3, out t4) && aoCriar(pi.dwProcessId, criado); }
          catch (Exception) { registrou = false; }
          if (!registrou) {
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 5000);
            return new long[] { 2, 0 };
          }
        }
        bool dentro = false;
        if (!AssignProcessToJobObject(job, pi.hProcess) || !IsProcessInJob(pi.hProcess, job, out dentro) || !dentro) {
          int erro = Marshal.GetLastWin32Error();
          TerminateProcess(pi.hProcess, 1);
          WaitForSingleObject(pi.hProcess, 5000);
          return new long[] { 2, erro };
        }
        ResumeThread(pi.hThread);
        DateTime fim = DateTime.UtcNow.AddMilliseconds(limiteMs);
        bool saiu = false;
        while (DateTime.UtcNow < fim) {
          if (!saiu) saiu = WaitForSingleObject(pi.hProcess, 200) == 0;
          if (saiu) {
            if (Ativos(job) == 0) break;
            Thread.Sleep(200);
          }
        }
        if (!saiu || Ativos(job) != 0) {
          bool pediu = TerminateJobObject(job, 1);
          DateTime ate = DateTime.UtcNow.AddSeconds(30);
          while (DateTime.UtcNow < ate && Ativos(job) != 0) Thread.Sleep(100);
          // Sem a confirmação de zero processos, quem chama não pode limpar nada.
          if (!pediu || Ativos(job) != 0) return new long[] { 3, 0 };
          return new long[] { 1, 0 };
        }
        uint codigo;
        if (!GetExitCodeProcess(pi.hProcess, out codigo)) return new long[] { 2, Marshal.GetLastWin32Error() };
        return new long[] { 0, codigo };
      } finally { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    } finally { CloseHandle(job); }
  }
}
'@
}

# ---------------------------------------------------------------- arquivos
function Hora-Agora { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }

# Todo JSON gravado é UTF-8 sem BOM, por arquivo temporário na mesma pasta e troca de nome.
function Gravar-Atomico([string]$caminho, [string]$texto) {
  $pasta = [System.IO.Path]::GetDirectoryName($caminho)
  [void][System.IO.Directory]::CreateDirectory($pasta)
  $tmp = Join-Path $pasta ('.' + [System.IO.Path]::GetFileName($caminho) + '.' + $PID + '.tmp')
  [System.IO.File]::WriteAllText($tmp, $texto, (New-Object System.Text.UTF8Encoding $false))
  if ([System.IO.File]::Exists($caminho)) { [System.IO.File]::Replace($tmp, $caminho, [NullString]::Value) }
  else { [System.IO.File]::Move($tmp, $caminho) }
}

function Mesma-Pasta([string]$a, [string]$b) {
  try {
    $x = [System.IO.Path]::GetFullPath($a).TrimEnd('\')
    $y = [System.IO.Path]::GetFullPath($b).TrimEnd('\')
    return [string]::Equals($x, $y, [StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

# ---------------------------------------------------------------- HTTP (seção 5.1, item 6)
# Só o cliente do .NET dentro deste processo. O segredo entra no pedido pelo código nativo:
#   corpo-convite         corpo {"convite":...<Extra>}
#   cabecalho-convite     X-TSA-Convite
#   cabecalho-credencial  Authorization: Bearer <credencial de atualização>
# Sem redirecionamento: um cabeçalho com segredo não segue para outro endereço.
# Devolve @{ Codigo; Texto; Bytes; Completo }. -LimiteTexto: tamanho máximo de uma resposta em memória. Codigo 0 = sem resposta; -1 = credencial ilegível.
function Http-Pedir {
  param([string]$Metodo, [string]$Url, [string]$Segredo = '', [string]$Extra = '', [string]$Destino = '',
    [long]$Desde = 0, [long]$Limite = 0, [long]$LimiteTexto = 1048576)
  $r = @{ Codigo = 0; Texto = ''; Bytes = $null; Completo = $false }
  $resp = $null
  try {
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
    $req.Method = $Metodo
    $req.AllowAutoRedirect = $false
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $req.UserAgent = 'tsa-install.ps1'
    $req.ServicePoint.Expect100Continue = $false
    if ($Desde -gt 0) { $req.AddRange([long]$Desde) }
    if ($Segredo -ceq 'cabecalho-convite') { [TsaNativo2]::CabecalhoConvite($req, $script:I.Convite) }
    elseif ($Segredo -ceq 'cabecalho-credencial') {
      if (-not [TsaNativo2]::CabecalhoCredencial($req, ('tsa-atualizador:' + $script:I.Id))) { $r.Codigo = -1; return $r }
    }
    elseif ($Segredo -ceq 'corpo-convite') { [TsaNativo2]::CorpoConvite($req, $script:I.Convite, $Extra) }
    elseif ($Segredo -cne '') { throw 'segredo desconhecido' }
    try { $resp = $req.GetResponse() }
    catch {
      $ex = $_.Exception
      while ($null -ne $ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
      if ($null -eq $ex -or $null -eq $ex.Response) { return $r }
      $resp = $ex.Response
    }
    $r.Codigo = [int]$resp.StatusCode
    $entrada = $resp.GetResponseStream()
    $buf = New-Object 'byte[]' 65536
    if ($Destino -and ($r.Codigo -eq 200 -or $r.Codigo -eq 206)) {
      # 200 com pedido de retomada: o servidor mandou o arquivo inteiro; recomeça do zero.
      $modo = [System.IO.FileMode]::Create
      $total = [long]0
      if ($r.Codigo -eq 206) { $modo = [System.IO.FileMode]::Append; $total = $Desde }
      $saida = New-Object System.IO.FileStream ($Destino, $modo, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      try {
        while ($true) {
          $n = $entrada.Read($buf, 0, $buf.Length)
          if ($n -le 0) { break }
          $total += $n
          if ($Limite -gt 0 -and $total -gt $Limite) { throw 'maior que o manifesto' }
          $saida.Write($buf, 0, $n)
        }
        $r.Completo = $true
      } finally { $saida.Dispose() }
    } else {
      $mem = New-Object System.IO.MemoryStream
      while ($mem.Length -le $LimiteTexto) {
        $n = $entrada.Read($buf, 0, $buf.Length)
        if ($n -le 0) { $r.Completo = $true; break }
        $mem.Write($buf, 0, $n)
      }
      if ($r.Completo) {
        $r.Bytes = $mem.ToArray()
        try { $r.Texto = (New-Object System.Text.UTF8Encoding $false, $true).GetString($r.Bytes) } catch { $r.Texto = '' }
      }
    }
  } catch {
    $r.Completo = $false
  } finally {
    if ($null -ne $resp) { try { $resp.Close() } catch { } }
  }
  return $r
}

# Lê a resposta como objeto JSON; $null se não for um objeto regular.
function Objeto-Da-Resposta($r) {
  if (-not $r.Completo) { return $null }
  try { $o = (Ler-JsonEstrito ([string]$r.Texto) $true).v } catch { return $null }
  if (-not (Eh-Objeto $o)) { return $null }
  return $o
}

# ---------------------------------------------------------------- ambiente (seção 5.1, item 3)
function Conferir-Ambiente {
  $v = [Environment]::OSVersion
  if ($v.Platform -ne [PlatformID]::Win32NT -or $v.Version.Major -lt 10 -or ($v.Version.Major -eq 10 -and $v.Version.Build -lt 19045)) {
    Parar 'O TSA precisa do Windows 10 (22H2) ou do Windows 11.'
  }
  $arq = $env:PROCESSOR_ARCHITEW6432
  if (-not $arq) { $arq = $env:PROCESSOR_ARCHITECTURE }
  if ($arq -cne 'AMD64') { Parar 'O TSA roda só em Windows de 64 bits (x64).' }
  if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { Parar 'Rode este comando no Windows PowerShell.' }
  $eu = New-Object System.Security.Principal.WindowsPrincipal ([System.Security.Principal.WindowsIdentity]::GetCurrent())
  if ($eu.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Parar "Rode sem 'Executar como administrador': o TSA é instalado no seu perfil."
  }
}

# Controle Inteligente de Aplicativos (seção 4, item 5). Ausente ou erro conta como desligado.
function Conferir-ControleInteligente {
  $estado = ''
  try {
    $s = Get-MpComputerStatus -ErrorAction Stop
    $p = $s.PSObject.Properties['SmartAppControlState']
    if ($null -ne $p -and $null -ne $p.Value) { $estado = [string]$p.Value }
  } catch { $estado = '' }
  if ($estado -ieq 'On') {
    Parar 'Este Windows está com o Controle Inteligente de Aplicativos ligado e não aceita o TSA sem certificado. Fale com o Cadu.'
  }
  if ($estado -ieq 'Eval') {
    Write-Host 'Aviso: o Controle Inteligente de Aplicativos deste Windows está em avaliação. Se a instalação for bloqueada, fale com o Cadu.' -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- trava (seção 6.3)
# Compartilhamento nenhum; o sistema solta quando este processo morre. Qualquer erro = ocupada.
function Pegar-Trava {
  if ($null -ne $script:I.TravaAberta) { return $true }
  try {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:I.Trava))
    $script:I.TravaAberta = [System.IO.File]::Open($script:I.Trava, [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    return $true
  } catch { $script:I.TravaAberta = $null; return $false }
}
function Soltar-Trava {
  if ($null -ne $script:I.TravaAberta) { try { $script:I.TravaAberta.Dispose() } catch { }; $script:I.TravaAberta = $null }
}

# ---------------------------------------------------------------- classificação (seção 5.3)
# troca em estado.json: 'objeto' (troca interrompida), 'null', 'ausente', 'ilegivel' ou 'outro'.
# Este arquivo é do atualizador, escrito com ConvertTo-Json (seção 7.1); não é o manifesto.
function Ler-Troca {
  # 'ausente' só com a falta comprovada do arquivo (ou da pasta dele). Acesso negado, erro de
  # leitura ou uma pasta com esse nome contam como ilegível.
  try {
    $atributos = [System.IO.File]::GetAttributes($script:I.Estado)
    if (($atributos -band [System.IO.FileAttributes]::Directory) -ne 0) { return 'ilegivel' }
  } catch {
    $ex = $_.Exception
    while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) { return 'ausente' }
    return 'ilegivel'
  }
  try { $o = ConvertFrom-Json ([System.IO.File]::ReadAllText($script:I.Estado, [System.Text.Encoding]::UTF8)) }
  catch { return 'ilegivel' }
  if (-not ($o -is [System.Management.Automation.PSCustomObject])) { return 'ilegivel' }
  $p = $o.PSObject.Properties['troca']
  if ($null -eq $p) { return 'ilegivel' }
  if ($null -eq $p.Value) { return 'null' }
  if ($p.Value -is [System.Management.Automation.PSCustomObject]) { return 'objeto' }
  return 'outro'
}

function Caminho-PowerShell {
  $sys = 'System32'
  if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { $sys = 'Sysnative' }
  return (Join-Path $env:SystemRoot "$sys\WindowsPowerShell\v1.0\powershell.exe")
}

# Linha de chamada da seção 7.1. A política vale só para esse processo.
function Rodar-Atualizador([string]$opcao) {
  $ps = Caminho-PowerShell
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:I.Atualizador $opcao | Out-Host
  return [int]$LASTEXITCODE
}

# Antes de classificar, item 1: troca interrompida.
function Retomar-Troca {
  if ((Ler-Troca) -cne 'objeto') { return }
  if (-not [System.IO.File]::Exists($script:I.Atualizador)) { Parar 'Há uma atualização interrompida. Fale com o Cadu.' }
  $rc = 1
  try { $rc = Rodar-Atualizador '-Retomar' } catch { $rc = 1 }
  # Só segue com o estado lido e "troca": null explícito.
  if ($rc -ne 0 -or (Ler-Troca) -cne 'null') { Parar 'Há uma atualização interrompida. Fale com o Cadu.' }
}

# ---------------------------------------------------------------- instalador que sobrou (5.4, item 4)
# Registro que persiste entre execuções: $TSAL\atualizacao\instalador-pendente.json. A identidade
# de um processo é o número mais a hora de criação (o Windows reaproveita o número).
function Mesma-Hora([datetime]$a, [datetime]$b) { return ([Math]::Abs(($a - $b).TotalMilliseconds) -le 1) }

# Devolve @{ Estado; Lista }: Estado 'ausente', 'ok' ou 'ilegivel' (que conta como bloqueio).
function Ler-Pendentes {
  $r = @{ Estado = 'ilegivel'; Lista = (New-Object System.Collections.ArrayList) }
  $ha = Existe-Comprovado $script:I.Pendente
  if ($ha -ceq 'nao') { $r.Estado = 'ausente'; return $r }
  if ($ha -cne 'sim') { return $r }
  try {
    $o = Ler-JsonArquivo $script:I.Pendente
    if (-not (Eh-Objeto $o) -or $o.get_Count() -ne 2 -or (Campo-Texto $o 'schema') -cne 'tsa.instalador.pendente/v1' -or -not $o.Contains('processos')) { return $r }
    $lista = $o['processos']
    if (-not ($lista -is [System.Collections.ArrayList])) { return $r }
    foreach ($x in $lista) {
      if (-not (Eh-Objeto $x) -or $x.get_Count() -ne 3 -or -not $x.Contains('pid')) { return $r }
      $id = $x['pid']; $quando = Campo-Texto $x 'criado_em'; $exe = Campo-Texto $x 'executavel'
      if (-not ($id -is [long]) -or $id -lt 1 -or $id -gt 4294967295 -or $null -eq $quando -or $null -eq $exe) { return $r }
      if ($quando -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { return $r }
      $hora = [DateTime]::Parse($quando, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
      [void]$r.Lista.Add(@{ Id = [int]$id; Criado = $hora; Exe = $exe; Proc = $null })
    }
    $r.Estado = 'ok'
  } catch { $r.Estado = 'ilegivel'; $r.Lista.Clear() }
  return $r
}

# Grava a lista inteira (escrita atômica). Lista vazia apaga o arquivo.
function Gravar-Pendentes($lista) {
  $partes = New-Object System.Collections.Generic.List[string]
  foreach ($e in $lista) {
    $partes.Add('{ "pid": ' + ([int]$e.Id).ToString([Globalization.CultureInfo]::InvariantCulture) + ', "criado_em": "' +
      $e.Criado.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture) + '", "executavel": ' + (Tsa-Aspas ([string]$e.Exe)) + ' }')
  }
  if ($partes.Count -eq 0) {
    if ((Existe-Comprovado $script:I.Pendente) -cne 'nao') { [System.IO.File]::Delete($script:I.Pendente) }
    return
  }
  Gravar-Atomico $script:I.Pendente ('{ "schema": "tsa.instalador.pendente/v1", "processos": [ ' + [string]::Join(', ', $partes.ToArray()) + ' ] }' + "`n")
}

# Acrescenta uma entrada. Devolve $true só com a entrada gravada.
function Registrar-Pendente([int]$id, [datetime]$criado, [string]$exe) {
  $lido = Ler-Pendentes
  if ($lido.Estado -ceq 'ilegivel') { return $false }
  [void]$lido.Lista.Add(@{ Id = $id; Criado = $criado; Exe = $exe; Proc = $null })
  Gravar-Pendentes $lido.Lista
  return $true
}

# Tira uma entrada (fim normal do instalador, com o objeto de trabalho vazio).
function Baixar-Pendente([int]$id, [datetime]$criado) {
  $lido = Ler-Pendentes
  if ($lido.Estado -cne 'ok') { return }
  $fica = New-Object System.Collections.ArrayList
  foreach ($e in $lido.Lista) { if (-not ($e.Id -eq $id -and (Mesma-Hora $e.Criado $criado))) { [void]$fica.Add($e) } }
  Gravar-Pendentes $fica
}

# Varredura. Só roda com a trava na mão: aí não existe outro script coordenando, e o que sobrar é
# órfão. Candidatos: as entradas do arquivo que ainda estão vivas, mais todo processo com
# executável em baixado\, em tmp\ ou igual a $APP\Uninstall TSA.exe, mais os descendentes de cada
# um (filho = aponta para o pai e nasceu depois dele). Todos entram no arquivo ANTES de qualquer
# tentativa de encerrar. Depois encerra e espera até 30 s. Devolve $true só quando uma consulta
# mostra todas as entradas fora da lista de processos e nenhum candidato novo; aí o arquivo sai.
# Arquivo ilegível, lista de processos que não vem ou entrada ainda viva no prazo: $false, e quem
# chama não mexe em nada. A entrada viva fica no arquivo e segura as execuções seguintes.
function Encerrar-Sobras {
  if ($null -eq $script:I.TravaAberta) { return $false }
  $lido = Ler-Pendentes
  if ($lido.Estado -ceq 'ilegivel') { return $false }
  # Entradas desta varredura, vivas ou não: uma entrada que já saiu ainda serve para reconhecer
  # o filho dela na consulta seguinte.
  $entradas = New-Object System.Collections.ArrayList
  foreach ($e in $lido.Lista) { [void]$entradas.Add($e) }
  $pastas = @(($script:I.Baixado.TrimEnd('\') + '\'), ($script:I.TmpRaiz.TrimEnd('\') + '\'))
  $fim = [DateTime]::UtcNow.AddSeconds($script:I.SobraS)
  try {
    while ($true) {
      try { $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { return $false }
      $mapa = New-Object 'System.Collections.Generic.Dictionary[int,object]'
      foreach ($p in $procs) {
        if ($p.CreationDate -is [datetime]) {
          $mapa[[int]$p.ProcessId] = @{ Criado = $p.CreationDate.ToUniversalTime(); Pai = [int]$p.ParentProcessId; Exe = [string]$p.ExecutablePath }
        }
      }
      $novos = 0
      $mudou = $true
      while ($mudou) {
        $mudou = $false
        foreach ($id in @($mapa.Keys)) {
          if ($id -eq $PID) { continue }
          $proc = $mapa[$id]
          $ja = $false
          foreach ($e in $entradas) { if ($e.Id -eq $id -and (Mesma-Hora $e.Criado $proc.Criado)) { $ja = $true } }
          if ($ja) { continue }
          $eh = $false
          if ($proc.Exe) {
            $eh = [string]::Equals($proc.Exe, $script:I.Desinstalador, [StringComparison]::OrdinalIgnoreCase)
            foreach ($pasta in $pastas) { if ($proc.Exe.StartsWith($pasta, [StringComparison]::OrdinalIgnoreCase)) { $eh = $true } }
          }
          if (-not $eh) {
            foreach ($e in $entradas) {
              if ($e.Id -ne $proc.Pai -or $proc.Criado -lt $e.Criado) { continue }
              # Número do pai já reusado por outro processo: filho nascido depois desse outro não é da entrada.
              if ($mapa.ContainsKey($e.Id) -and -not (Mesma-Hora $mapa[$e.Id].Criado $e.Criado) -and $proc.Criado -ge $mapa[$e.Id].Criado) { continue }
              $eh = $true
            }
          }
          if ($eh) {
            [void]$entradas.Add(@{ Id = [int]$id; Criado = $proc.Criado; Exe = [string]$proc.Exe; Proc = $null })
            $novos++
            $mudou = $true
          }
        }
      }
      $vivas = New-Object System.Collections.ArrayList
      foreach ($e in $entradas) { if ($mapa.ContainsKey($e.Id) -and (Mesma-Hora $mapa[$e.Id].Criado $e.Criado)) { [void]$vivas.Add($e) } }
      # Antes de encerrar: o arquivo fica com tudo o que está vivo (quem já saiu sai do arquivo).
      try { Gravar-Pendentes $vivas } catch { return $false }
      if ($vivas.Count -eq 0 -and $novos -eq 0) { return $true }
      if ([DateTime]::UtcNow -ge $fim) { return $false }
      foreach ($e in $vivas) {
        # Encerra pela mesma instância: abre o identificador, confere a hora de criação e o guarda.
        try {
          if ($null -eq $e.Proc) {
            $alvo = [System.Diagnostics.Process]::GetProcessById($e.Id)
            [void]$alvo.Handle
            if (Mesma-Hora ($alvo.StartTime.ToUniversalTime()) $e.Criado) { $e.Proc = $alvo } else { $alvo.Dispose() }
          }
          if ($null -ne $e.Proc) { $e.Proc.Kill() }
        } catch { }
      }
      Start-Sleep -Milliseconds 500
    }
  } finally {
    foreach ($e in $entradas) { if ($null -ne $e.Proc) { try { $e.Proc.Dispose() } catch { } } }
  }
}

# Marca de primeira instalação (seção 5.3). Devolve @{ Estado; Id; Fase; Build; Hora; Sha }:
# Estado 'ausente', 'invalida' (não lê ou fora do formato: nunca autoriza apagar nada) ou 'ok'.
# Id é a identidade da tentativa: sha256 e iniciada_em.
function Ler-Marca {
  $r = @{ Estado = 'invalida'; Id = ''; Fase = ''; Build = ''; Hora = ''; Sha = '' }
  try { [void][System.IO.File]::GetAttributes($script:I.Primeira) }
  catch {
    $ex = $_.Exception
    while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) { $r.Estado = 'ausente' }
    return $r
  }
  try { $o = Ler-JsonArquivo $script:I.Primeira } catch { return $r }
  if (-not (Eh-Objeto $o) -or $o.get_Count() -ne 5) { return $r }
  $fase = Campo-Texto $o 'fase'; $sha = Campo-Texto $o 'sha256'; $build = Campo-Texto $o 'build_id'; $hora = Campo-Texto $o 'iniciada_em'
  if ((Campo-Texto $o 'schema') -cne 'tsa.instalacao.primeira/v1') { return $r }
  if (@('instalando', 'instalado', 'limpando') -cnotcontains $fase) { return $r }
  if ($null -eq $sha -or $sha -cnotmatch '\A[0-9a-f]{64}\z') { return $r }
  if ((Tsa-BuildIdValido $build) -ne $true) { return $r }
  if ($null -eq $hora -or $hora -cnotmatch '\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z\z') { return $r }
  if ((Tsa-DataHoraExiste ([int]$Matches[1]) ([int]$Matches[2]) ([int]$Matches[3]) ([int]$Matches[4]) ([int]$Matches[5]) ([int]$Matches[6])) -ne $true) { return $r }
  return @{ Estado = 'ok'; Id = ($sha + '|' + $hora); Fase = $fase; Build = $build; Hora = $hora; Sha = $sha }
}

function Gravar-Marca([string]$fase, [string]$sha, [string]$build, [string]$hora) {
  Gravar-Atomico $script:I.Primeira ('{ "schema": "tsa.instalacao.primeira/v1", "fase": "' + $fase + '", "sha256": "' + $sha + '", "build_id": "' + $build + '", "iniciada_em": "' + $hora + '" }' + "`n")
}

# Atalho TSA.lnk do usuário cujo destino é $APP\TSA.exe (atalho com outro destino fica).
function Apagar-Atalhos {
  $pastas = @([Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('StartMenu'))
  $shell = $null
  foreach ($pasta in $pastas) {
    if (-not $pasta) { continue }
    $lnk = Join-Path $pasta 'TSA.lnk'
    $ha = Existe-Comprovado $lnk
    if ($ha -ceq 'nao') { continue }
    if ($ha -cne 'sim') { throw 'atalho que não dá para conferir' }
    if ($null -eq $shell) { $shell = New-Object -ComObject WScript.Shell }
    $destino = [string]$shell.CreateShortcut($lnk).TargetPath
    if ([string]::Equals($destino, $script:I.AppExe, [StringComparison]::OrdinalIgnoreCase)) { [System.IO.File]::Delete($lnk) }
  }
}

# Limpeza de uma primeira instalação que não terminou (seção 5.3). Só com a marca válida e a trava
# na mão; só aqui e na falha do passo 7. Sem desinstalador: nenhum script o executa (5.4, item 3).
# Antes de apagar, a marca passa para a fase limpando. Ordem: pasta $APP; atalhos que apontam
# para $APP\TSA.exe; chave exata do registro, só se a pasta registrada é $APP. Com os três passos
# feitos, apaga a marca. Devolve $true só com tudo feito; qualquer falha mantém a marca.
function Limpar-Primeira($marca) {
  if ($null -eq $script:I.TravaAberta -or $marca.Estado -cne 'ok') { return $false }
  try {
    if ((Encerrar-Sobras) -ne $true) { return $false }
    Gravar-Marca 'limpando' $marca.Sha $marca.Build $marca.Hora
    if ([System.IO.Directory]::Exists($script:I.App)) { [System.IO.Directory]::Delete($script:I.App, $true) }
    # Só segue com a falta comprovada da pasta.
    if ((Existe-Comprovado $script:I.App) -cne 'nao') { return $false }
    Apagar-Atalhos
    if ((Ler-Registro) -ceq 'app') {
      $u = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall', $true)
      if ($null -eq $u) { return $false }
      try { $u.DeleteSubKeyTree($script:I.ChaveRegistro, $false) } finally { $u.Dispose() }
    }
    # Só conclui com o registro comprovadamente sem o TSA; leitura inconclusiva mantém a marca.
    if ((Ler-Registro) -cne 'nenhum') { return $false }
    [System.IO.File]::Delete($script:I.Primeira)
    return (-not [System.IO.File]::Exists($script:I.Primeira))
  } catch { return $false }
}

# 'sim', 'nao' (falta comprovada) ou 'duvida' (acesso negado ou outro erro).
function Existe-Comprovado([string]$caminho) {
  try { [void][System.IO.File]::GetAttributes($caminho); return 'sim' }
  catch {
    $ex = $_.Exception
    while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) { return 'nao' }
    return 'duvida'
  }
}

# Sinal de uso do TSA em $APP: processo do app aberto, cadastro, ou saúde gravada depois do começo
# da tentativa. Na dúvida (lista de processos ou arquivo que não lê), conta como uso.
function Ha-SinalDeUso($marca) {
  try {
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
      if ([string]::Equals([string]$p.ExecutablePath, $script:I.AppExe, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
  } catch { return $true }
  if ((Existe-Comprovado $script:I.Instalacao) -cne 'nao') { return $true }
  $saude = Join-Path $script:I.Tsal 'saude.json'
  if ((Existe-Comprovado $saude) -cne 'nao') {
    try { $quando = Campo-Texto (Ler-JsonArquivo $saude) 'gravado_em' } catch { return $true }
    if ($null -eq $quando -or $quando -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z\z') { return $true }
    if ([string]::CompareOrdinal($quando.Substring(0, 19), $marca.Hora.Substring(0, 19)) -ge 0) { return $true }
  }
  return $false
}

# Antes de classificar, item 2: primeira instalação interrompida. Devolve $true quando a outra
# execução terminou enquanto esta esperava a trava: nada é apagado e a classificação recomeça.
function Recuperar-Primeira {
  $antes = Ler-Marca
  if ($antes.Estado -ceq 'ausente') { return $false }
  $naoTerminou = 'Há uma instalação do TSA que não terminou direito. Fale com o Cadu.'
  if ($antes.Estado -cne 'ok') { Parar $naoTerminou }
  if (-not (Pegar-Trava)) { Parar 'Há outra instalação em andamento. Espere terminar e rode o comando de novo.' }
  try {
    # Com a trava na mão, lê de novo: a marca tem de ser a mesma, e não pode haver troca.
    $marca = Ler-Marca
    $troca = Ler-Troca
    if ($marca.Estado -ceq 'ausente' -or ($marca.Estado -ceq 'ok' -and $marca.Id -cne $antes.Id) -or $troca -ceq 'objeto') { return $true }
    if ($marca.Estado -cne 'ok') { Parar $naoTerminou }
    if ($troca -cne 'ausente' -and $troca -cne 'null') { Parar 'Há uma atualização interrompida. Fale com o Cadu.' }
    # A marca sozinha não autoriza apagar nada. A primeira regra que casa vale.
    # Registro conflitante: não toca em nada; a classificação dá o caso D.
    if ((Ler-Registro) -ceq 'conflito') { return $false }
    # Fase instalado: o instalador terminou e o build_id foi conferido. Só preserva: apaga a marca
    # e segue. Vem antes da conferência de identidade e uso (no caso C o cadastro já existe).
    if ($marca.Fase -ceq 'instalado') {
      [System.IO.File]::Delete($script:I.Primeira)
      $script:I.ConviteNaoEntregue = $true
      return $false
    }
    # Identidade divergente (o que está em $APP não é desta tentativa) ou sinal de uso.
    $versao = Join-Path $script:I.App 'resources\tsa\tsa-version.json'
    if ([System.IO.File]::Exists($versao)) {
      $instalado = Ler-BuildInstalado
      if ($instalado -cne '' -and $instalado -cne $marca.Build) { Parar $naoTerminou }
    }
    if ((Ha-SinalDeUso $marca) -ne $false) { Parar $naoTerminou }
    # instalando (o script morreu com o instalador em andamento) ou limpando (limpeza pela metade).
    Dizer 'Uma instalação anterior parou no meio. Limpando...'
    if ((Limpar-Primeira $marca) -ne $true) { Parar 'Não deu para limpar a instalação que falhou. Fale com o Cadu.' }
  } finally { Soltar-Trava }
  return $false
}

function Esta-Cadastrada {
  $script:I.Id = ''
  $script:I.Api = ''
  if (-not [System.IO.File]::Exists($script:I.Instalacao)) { return $false }
  try { $o = Ler-JsonArquivo $script:I.Instalacao } catch { return $false }
  $id = Campo-Texto $o 'installation_id'
  $api = Campo-Texto $o 'api'
  if ($null -eq $id -or $null -eq $api) { return $false }
  if ($id -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { return $false }
  if ($api -cnotmatch $script:I.ReApi) { return $false }
  if ([TsaNativo2]::CredExiste('tsa-atualizador:' + $id) -ne $true) { return $false }
  $script:I.Id = $id
  $script:I.Api = $api
  return $true
}

# Registro do TSA (seção 5.3). Devolve 'nenhum', 'app' (registrado em $APP) ou 'conflito'.
# A entrada do TSA é a chave exata em HKCU; a pasta registrada é a pasta do executável que é o
# primeiro termo do UninstallString, lido respeitando as aspas (o InstallLocation vem vazio).
# Conflito: a chave exata aponta para outra pasta; ou outra entrada, em HKCU ou HKLM, cita um
# "Uninstall TSA.exe" fora de $APP. Chave que não lê ou texto com mais de uma leitura: conflito.
# $script:I.RegistroPasta fica com a pasta só quando o conflito é uma instalação identificada: a
# chave exata, legível, apontando para uma pasta que existe e tem TSA.exe, sem outro conflito.
function Ler-Registro {
  $script:I.RegistroPasta = ''
  $caminho = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
  $noApp = $false
  $fora = ''
  $outro = $false
  try {
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
      foreach ($vista in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $u = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $vista).OpenSubKey($caminho)
        if ($null -eq $u) { continue }
        foreach ($nome in $u.GetSubKeyNames()) {
          $k = $u.OpenSubKey($nome)
          if ($null -eq $k) { $outro = $true; continue }
          $valor = $k.GetValue('UninstallString', $null)
          $exata = ($hive -eq [Microsoft.Win32.RegistryHive]::CurrentUser -and [string]::Equals($nome, $script:I.ChaveRegistro, [StringComparison]::OrdinalIgnoreCase))
          if ($exata) {
            $exe = $null
            if ($valor -is [string]) {
              if ($valor -match '\A\s*"([^"]+)"(\s|\z)') { $exe = $Matches[1] }
              elseif ($valor -match '\A\s*([^\s"]+)\s*\z') { $exe = $Matches[1] }
            }
            if (-not $exe) { $outro = $true; continue }
            $pasta = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($exe))
            if (Mesma-Pasta $pasta $script:I.App) { $noApp = $true }
            elseif ($fora -and -not (Mesma-Pasta $pasta $fora)) { $outro = $true }
            else { $fora = $pasta }
            continue
          }
          if ($valor -is [string] -and $valor -match 'Uninstall TSA\.exe') {
            $achados = [regex]::Matches($valor, '(?i)([A-Za-z]:\\[^"<>|?*]*?)\\Uninstall TSA\.exe')
            if ($achados.Count -eq 0) { $outro = $true }
            foreach ($m in $achados) { if (-not (Mesma-Pasta $m.Groups[1].Value $script:I.App)) { $outro = $true } }
          }
        }
      }
    }
  } catch { return 'conflito' }
  if ($outro -or $fora) {
    if ($fora -and -not $outro -and -not $noApp -and (Existe-Comprovado (Join-Path $fora 'TSA.exe')) -ceq 'sim') { $script:I.RegistroPasta = $fora }
    return 'conflito'
  }
  if ($noApp) { return 'app' }
  return 'nenhum'
}

# O caso D tem precedência sobre todos: com registro conflitante o instalador apagaria o TSA da
# outra pasta, então o script não instala, não atualiza e não limpa nada.
function Classificar {
  $cadastrada = ((Esta-Cadastrada) -eq $true)
  if ((Ler-Registro) -ceq 'conflito') { return 'D' }
  # Presença, falta comprovada ou dúvida: com dúvida sobre o TSA.exe, ninguém instala.
  $app = Existe-Comprovado $script:I.AppExe
  if ($app -ceq 'duvida') { return 'duvida' }
  if ($app -ceq 'sim') {
    if ($cadastrada) { return 'B1' }
    return 'B2'
  }
  if ($cadastrada) { return 'C' }
  return 'A'
}

# ---------------------------------------------------------------- convite e setor
# Seção 5.1, item 4: Read-Host -AsSecureString; o texto só é aberto na hora de cada envio, dentro
# do código nativo. Nunca vai em argumento, variável de ambiente, arquivo, saída nem log.
function Pedir-Convite {
  for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
    $lido = Read-Host -AsSecureString 'Cole o seu convite e aperte Enter (aparecem asteriscos no lugar dele)'
    if (-not ($lido -is [System.Security.SecureString])) { Parar 'Sem resposta do convite. Rode o comando de novo.' }
    $s = [TsaNativo2]::Aparar($lido)
    $lido.Dispose()
    if ([TsaNativo2]::ConviteFormato($s) -ne $true) {
      $s.Dispose()
      Write-Host '  O convite tem 43 caracteres. Confira e cole de novo.'
      continue
    }
    $script:I.Convite = $s
    $r = Http-Pedir -Metodo 'POST' -Url ($script:I.PainelApi + '/convite/validar') -Segredo 'corpo-convite'
    $o = Objeto-Da-Resposta $r
    if ($r.Codigo -eq 200) {
      if ($null -eq $o -or -not $o.Contains('valido') -or $o['valido'] -isnot [bool] -or $o['valido'] -ne $true) {
        Parar 'Resposta estranha da Central. Tente de novo mais tarde.'
      }
      $sugerido = Campo-Texto $o 'perfil_sugerido'
      if ($null -ne $sugerido -and $script:I.Perfis -ccontains $sugerido) { $script:I.PerfilSugerido = $sugerido }
      Feito 'Convite válido'
      return
    }
    if ($r.Codigo -eq 401) {
      $script:I.Convite.Dispose()
      $script:I.Convite = $null
      Write-Host '  Convite não reconhecido. Confira e cole de novo.'
      continue
    }
    if ($r.Codigo -eq 410) {
      $erro = Campo-Texto $o 'error'
      if ($erro -ceq 'convite_usado') { Parar 'Este convite já foi usado. Peça outro ao Cadu.' }
      if ($erro -ceq 'convite_expirado') { Parar 'Este convite venceu. Peça outro ao Cadu.' }
      Parar 'Este convite foi cancelado. Peça outro ao Cadu.'
    }
    if ($r.Codigo -eq 429) { Parar 'Muitas tentativas. Espere uma hora e rode o comando de novo.' }
    Parar "Não consegui falar com a Central (código $($r.Codigo)). Tente de novo em alguns minutos."
  }
  Parar 'Três tentativas sem convite válido. Peça o convite de novo ao Cadu.'
}

function Perguntar-Setor {
  if ($script:I.Perfil) { return }
  while ($true) {
    Write-Host ''
    Write-Host 'Qual é o seu setor?'
    Write-Host '  1. Tráfego'
    Write-Host '  2. Audiovisual'
    Write-Host '  3. Copy e Criativos'
    Write-Host '  4. CS/operacional'
    Write-Host '  5. Gestão'
    if ($script:I.PerfilSugerido) { Write-Host "(O Cadu sugeriu: $($script:I.PerfilSugerido))" }
    $r = Read-Host 'Digite o número e aperte Enter'
    if ($null -eq $r) { Parar 'Sem resposta do setor. Rode o comando de novo.' }
    $r = ([string]$r).Trim()
    if ($r -cmatch '\A[1-5]\z') { $script:I.Perfil = $script:I.Perfis[[int]$r - 1]; return }
    Write-Host '  Escolha um número de 1 a 5.'
  }
}

# ---------------------------------------------------------------- manifesto e download
# Caso A pela rota do convite; caso C pela credencial de atualização. Devolve o objeto da resposta.
function Pedir-Manifesto {
  if ($script:I.Caso -ceq 'A') {
    $r = Http-Pedir -Metodo 'POST' -Url ($script:I.PainelApi + '/release/nova-instalacao') -Segredo 'corpo-convite' `
      -Extra ',"plataforma":"win32","arquitetura":"x64"'
  } else {
    $r = Http-Pedir -Metodo 'GET' -Url ($script:I.Api + '/v1/app/release?plataforma=win32&arquitetura=x64') -Segredo 'cabecalho-credencial'
  }
  if ($r.Codigo -eq 200) {
    $o = Objeto-Da-Resposta $r
    if ($null -eq $o) { Parar $script:I.FraseFalha }
    return $o
  }
  if ($r.Codigo -eq 204) { Parar 'Ainda não há versão liberada. Fale com o Cadu.' }
  if ($r.Codigo -eq 410) { Parar 'O convite deixou de valer. Peça outro ao Cadu.' }
  if ($r.Codigo -eq 401 -or $r.Codigo -eq 403 -or $r.Codigo -eq -1) { Parar 'A Central não aceitou o acesso desta máquina. Fale com o Cadu.' }
  if ($r.Codigo -eq 429) { Parar 'Muitas tentativas. Espere uma hora e rode o comando de novo.' }
  Parar "Não consegui falar com a Central (código $($r.Codigo)). Tente de novo em alguns minutos."
}

# Passo 3: assinatura e campos, antes de baixar. Só daqui saem os dados usados no download.
function Conferir-Manifesto($resposta) {
  $script:I.M = $null
  if (-not (Eh-Objeto $resposta) -or -not $resposta.Contains('manifesto')) { Parar $script:I.FraseFalha }
  $m = $resposta['manifesto']
  $v = Tsa-VerificarArvore $m (Chaves-Confiaveis)
  if (-not ($v -is [hashtable]) -or $v['ok'] -isnot [bool] -or $v['ok'] -ne $true) { Parar $script:I.FraseFalha }
  if ($m['plataforma'] -cne 'win32' -or $m['arquitetura'] -cne 'x64' -or $m['app_id'] -cne $script:I.AppId) { Parar $script:I.FraseFalha }
  $script:I.M = @{
    BuildId = [string]$m['build_id']
    Sha = [string]$m['artefato']['sha256']
    Bytes = [long]$m['artefato']['bytes']
    Versao = [string]$m['versao']
  }
  Feito "Assinatura da versão $($script:I.M.Versao) conferida"
}

# Passo 4: baixa para a pasta temporária, com retomada por Range. Resposta de erro apaga o
# parcial (o corpo do erro não pode virar começo do instalador).
function Baixar-Artefato {
  $m = $script:I.M
  if ($null -eq $m) { Parar $script:I.FraseFalha }
  $destino = Join-Path $script:I.Tmp 'tsa-windows-x64.exe'
  if ($script:I.Caso -ceq 'A') { $url = $script:I.PainelApi + '/artefatos/' + $m.Sha; $segredo = 'cabecalho-convite' }
  else { $url = $script:I.Api + '/v1/app/artefatos/' + $m.Sha; $segredo = 'cabecalho-credencial' }
  Dizer "Baixando o TSA $($m.Versao)..."
  for ($tentativa = 1; $tentativa -le 5; $tentativa++) {
    $ja = [long]0
    if ([System.IO.File]::Exists($destino)) { $ja = (New-Object System.IO.FileInfo $destino).Length }
    if ($ja -gt $m.Bytes) { [System.IO.File]::Delete($destino); $ja = [long]0 }
    if ($ja -gt 0 -and $ja -eq $m.Bytes) { break }
    $r = Http-Pedir -Metodo 'GET' -Url $url -Segredo $segredo -Destino $destino -Desde $ja -Limite $m.Bytes
    if (($r.Codigo -eq 200 -or $r.Codigo -eq 206) -and $r.Completo) { break }
    if ($r.Codigo -ne 200 -and $r.Codigo -ne 206 -and $r.Codigo -ne 0) {
      if ([System.IO.File]::Exists($destino)) { [System.IO.File]::Delete($destino) }
    }
    if ($tentativa -eq 5) {
      if ([System.IO.File]::Exists($destino)) { [System.IO.File]::Delete($destino) }
      Parar "O download não terminou (código $($r.Codigo)). Tente de novo em alguns minutos."
    }
    Start-Sleep -Seconds $script:I.EsperaDownloadS
  }
  return $destino
}

# Seção 5.4, item 1, caminho sem desvio. Abre o arquivo só para leitura, com compartilhamento só
# de leitura (ninguém escreve, apaga nem troca o nome enquanto o identificador existir), e exige:
# - nem o arquivo nem pasta acima dele, até %LOCALAPPDATA% inclusive, é ponto de nova análise
#   (junção ou atalho de pasta);
# - o arquivo fica dentro de $base;
# - o caminho final que o sistema dá para o identificador é o esperado. A conta parte do caminho
#   final de %LOCALAPPDATA% (nome curto ou unidade mapeada não reprovam); daí para baixo não pode
#   haver diferença.
# Devolve @{ Fluxo; Final }: o identificador aberto e o caminho final, por onde o arquivo é
# executado. Devolve $null, com o arquivo fechado, se algo não confere.
function Abrir-Protegido([string]$caminho, [string]$base) {
  $fs = $null
  try {
    $raiz = [System.IO.Path]::GetFullPath($script:I.Local).TrimEnd('\')
    $cheio = [System.IO.Path]::GetFullPath($caminho)
    $dentro = [System.IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
    if (-not $cheio.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not $cheio.StartsWith($dentro, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $atual = $cheio
    while ($true) {
      if (([System.IO.File]::GetAttributes($atual) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
      if ($atual.Length -le $raiz.Length) { break }
      $atual = [System.IO.Path]::GetDirectoryName($atual)
      if (-not $atual) { return $null }
    }
    if (-not [string]::Equals($atual, $raiz, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $fs = [System.IO.File]::Open($cheio, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $final = [TsaNativo2]::CaminhoFinal($fs.SafeFileHandle)
    $raizFinal = [TsaNativo2]::CaminhoFinalDaPasta($raiz)
    if ($final -is [string] -and $raizFinal -is [string] -and
      [string]::Equals($final, ($raizFinal.TrimEnd('\') + $cheio.Substring($raiz.Length)), [StringComparison]::OrdinalIgnoreCase)) {
      if ($final.StartsWith('\\?\') -and -not $final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $final = $final.Substring(4) }
      return @{ Fluxo = $fs; Final = $final }
    }
  } catch { }
  if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
  return $null
}

# Passo 5: confere tamanho e SHA-256 pelo identificador que fica aberto até o fim. Devolve o mesmo
# que Abrir-Protegido, ou $null, com o arquivo fechado, se não confere.
function Abrir-Conferido([string]$caminho, [long]$bytes, [string]$sha, [string]$base = '') {
  if (-not $base) { $base = $script:I.Tsal }
  try { Unblock-File -LiteralPath $caminho -ErrorAction Stop } catch { }
  $a = Abrir-Protegido $caminho $base
  if ($null -eq $a) { return $null }
  $confere = $false
  try {
    if ($a.Fluxo.Length -eq $bytes) {
      $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
      try { $hex = ([BitConverter]::ToString($h.ComputeHash($a.Fluxo)) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
      $confere = ($sha -cmatch '\A[0-9a-f]{64}\z' -and $hex -ceq $sha)
    }
  } catch { $confere = $false }
  if ($confere -ne $true) {
    try { $a.Fluxo.Dispose() } catch { }
    return $null
  }
  return $a
}

function Fechar-Exe {
  if ($null -ne $script:I.ExeAberto) { try { $script:I.ExeAberto.Fluxo.Dispose() } catch { }; $script:I.ExeAberto = $null }
}

function Ler-BuildInstalado {
  try { $o = Ler-JsonArquivo (Join-Path $script:I.App 'resources\tsa\tsa-version.json') } catch { return '' }
  $b = Campo-Texto $o 'build_id'
  if ($null -eq $b) { return '' }
  return $b
}

# ---------------------------------------------------------------- instalação (passo 7)
# Só roda quando não tem TSA (casos A e C). Executa o arquivo que $script:I.ExeAberto mantém
# aberto, pelo caminho final conferido.
function Instalar {
  $m = $script:I.M
  if ($null -eq $m -or $null -eq $script:I.ExeAberto) { Parar $script:I.FraseFalha }
  # (a) Reconsulta: a release ainda é a mesma (pausa ou troca no meio do download para aqui).
  $de_novo = Pedir-Manifesto
  $m2 = $null
  if ((Eh-Objeto $de_novo) -and $de_novo.Contains('manifesto')) { $m2 = $de_novo['manifesto'] }
  $build2 = Campo-Texto $m2 'build_id'
  $sha2 = $null
  if ((Eh-Objeto $m2) -and $m2.Contains('artefato')) { $sha2 = Campo-Texto $m2['artefato'] 'sha256' }
  if ($null -eq $build2 -or $null -eq $sha2 -or $build2 -cne $m.BuildId -or $sha2 -cne $m.Sha) {
    Parar 'A versão mudou durante o download. Rode o comando de novo.'
  }
  # (b) Trava.
  if (-not (Pegar-Trava)) { Parar 'Há outra atualização em andamento. Espere terminar e rode o comando de novo.' }
  # (c) Reclassifica dentro da trava: outro instalador pode ter terminado enquanto este baixava.
  $troca = Ler-Troca
  if (($troca -cne 'ausente' -and $troca -cne 'null') -or (Ler-Marca).Estado -cne 'ausente' -or (Classificar) -cne $script:I.Caso) {
    Soltar-Trava
    Parar 'O TSA já foi instalado neste computador. Abra o TSA.'
  }
  # Instalador de outra tentativa que ainda pode estar escrevendo segura tudo (5.4, item 4).
  if ((Ler-Pendentes).Estado -cne 'ausente' -and (Encerrar-Sobras) -ne $true) {
    Soltar-Trava
    Parar 'Há um instalador do TSA que não terminou. Nada foi mudado. Fale com o Cadu.'
  }
  # (d) Marca: a partir daqui, o que estiver em $APP foi posto por este script.
  $hora = Hora-Agora
  Gravar-Marca 'instalando' $m.Sha $m.BuildId $hora
  Dizer 'Instalando...'
  $certo = $false
  $arvoreViva = $false
  try {
    # (e) Instalador NSIS em modo silencioso; /D= é o último argumento, sem aspas.
    # O instalador nasce suspenso e é gravado no registro de pendentes antes de andar.
    $script:I.InstaladorId = $null
    $aoCriar = [Func[int, long, bool]] {
      param($id, $quando)
      $ok = $false
      try {
        $criado = [DateTime]::FromFileTimeUtc($quando)
        if ((Registrar-Pendente $id $criado $script:I.ExeAberto.Final) -eq $true) { $script:I.InstaladorId = @{ Id = $id; Criado = $criado }; $ok = $true }
      } catch { $ok = $false }
      return $ok
    }
    $r = [TsaNativo2]::Executar($script:I.ExeAberto.Final, ('/S /D=' + $script:I.App), $script:I.InstaladorS * 1000, $aoCriar)
    $arvoreViva = ($r[0] -eq 3)
    # Fim com o objeto de trabalho vazio (saiu, ou foi encerrado e confirmado): a entrada sai.
    if (($r[0] -eq 0 -or $r[0] -eq 1) -and $null -ne $script:I.InstaladorId) { Baixar-Pendente $script:I.InstaladorId.Id $script:I.InstaladorId.Criado }
    if ($r[0] -eq 0 -and $r[1] -eq 0 -and [System.IO.File]::Exists($script:I.AppExe)) {
      # (f) O que foi instalado é a build do manifesto.
      $certo = ((Ler-BuildInstalado) -ceq $m.BuildId)
    }
  } catch { $certo = $false }
  Fechar-Exe
  if ($certo -ne $true) {
    # Sem confirmar que o instalador e os filhos saíram, nada é limpo: pasta e marca ficam.
    $limpou = $false
    if (-not $arvoreViva) { $limpou = Limpar-Primeira (Ler-Marca) }
    Soltar-Trava
    if ($limpou -ne $true) { Parar 'Não deu para limpar a instalação que falhou. Fale com o Cadu.' }
    Parar $script:I.FraseFalha
  }
  # (g)
  Gravar-Marca 'instalado' $m.Sha $m.BuildId $hora
  [System.IO.File]::Delete($script:I.Primeira)
  Soltar-Trava
  Feito "TSA $($m.Versao) instalado"
}

# ---------------------------------------------------------------- perfil, agendador, convite
function Gravar-Perfil {
  if ($script:I.Caso -ceq 'C' -and [System.IO.File]::Exists($script:I.PerfilJson)) { return }
  if (-not $script:I.Perfil) { Perguntar-Setor }
  Gravar-Atomico $script:I.PerfilJson ('{ "perfil": "' + $script:I.Perfil + '" }' + "`n")
}

function Marca-Agendador {
  if ($script:I.SemAgendador) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:I.SemAgendadorMarca))
    if (-not [System.IO.File]::Exists($script:I.SemAgendadorMarca)) { [System.IO.File]::WriteAllBytes($script:I.SemAgendadorMarca, (New-Object 'byte[]' 0)) }
  } elseif ([System.IO.File]::Exists($script:I.SemAgendadorMarca)) {
    [System.IO.File]::Delete($script:I.SemAgendadorMarca)
  }
}

# Passo 9: o convite vai ao Gerenciador de Credenciais pela API (CredWriteW), nunca pelo cmdkey.
function Entregar-Convite {
  try { [TsaNativo2]::CredGravar('tsa-convite-pendente', 'convite', $script:I.Convite) }
  catch { Parar 'Não consegui guardar o convite no Gerenciador de Credenciais. Fale com o Cadu.' }
  $script:I.Convite.Dispose()
  $script:I.Convite = $null
}

# ---------------------------------------------------------------- casos
function Caso-B1 {
  Marca-Agendador
  if (-not [System.IO.File]::Exists($script:I.Atualizador)) { Parar 'Abra o TSA uma vez e rode este comando de novo.' }
  Dizer 'O TSA já está instalado e cadastrado. Procurando atualização...'
  # Só vale o resumo gravado por esta execução: o mesmo arquivo de antes é resultado velho.
  $antes = Assinatura-Resumo
  $rc = 1
  try { $rc = Rodar-Atualizador '-Agora' } catch { $rc = 1 }
  if ($rc -ne 0) { Parar "O atualizador parou com erro ($rc). Fale com o Cadu." }
  $depois = Assinatura-Resumo
  if ($depois -ceq '' -or $depois -ceq $antes) { Parar 'O atualizador não deixou o resultado desta execução. Fale com o Cadu.' }
  $estado = 'desconhecido'
  try {
    $o = ConvertFrom-Json ([System.IO.File]::ReadAllText($script:I.Resumo, [System.Text.Encoding]::UTF8))
    $p = $o.PSObject.Properties['estado']
    if ($null -ne $p -and $p.Value -is [string] -and $p.Value -cmatch '\A[a-z_]{1,40}\z') { $estado = $p.Value }
  } catch { $estado = 'desconhecido' }
  Write-Host "Resultado: $estado"
}

function Assinatura-Resumo {
  try {
    if (-not [System.IO.File]::Exists($script:I.Resumo)) { return '' }
    $f = New-Object System.IO.FileInfo $script:I.Resumo
    return ($f.LastWriteTimeUtc.Ticks.ToString() + ' ' + $f.Length + ' ' + (Tsa-Sha256Hex ([System.IO.File]::ReadAllBytes($script:I.Resumo))))
  } catch { return '' }
}

# ---------------------------------------------------------------- pré-requisitos (passo 10)
# Roda um programa sem janela e devolve o código de saída; a saída é lida e descartada.
function Rodar-Programa([string]$exe, [string]$argumentos, [string]$pasta = '') {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $argumentos; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  if ($pasta) { $psi.WorkingDirectory = $pasta }
  $p = [System.Diagnostics.Process]::Start($psi)
  $erro = $p.StandardError.ReadToEndAsync()
  [void]$p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  [void]$erro.Result
  return [int]$p.ExitCode
}

# Identidade padrão do Git, quando a pessoa não tem nenhuma. Regra provisória (D-F4-6, pendente
# do Cadu) e ponto único: para trocar o padrão, é só aqui. user.name = o nome de usuário do
# Windows, como está. user.email = <local>@tsa.local: o nome em minúsculas, sem acento, com o
# que não for a-z ou 0-9 trocado por ponto, sem ponto repetido nem nas pontas; vazio vira usuario.
function Identidade-Git-Padrao([string]$usuario) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($c in $usuario.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
    if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
  }
  $local = ($sb.ToString().ToLowerInvariant() -creplace '[^a-z0-9]+', '.').Trim('.')
  if (-not $local) { $local = 'usuario' }
  return @{ 'user.name' = $usuario; 'user.email' = ($local + '@tsa.local') }
}

# Identidade do Git: lê a configuração efetiva, fora de qualquer repositório. Código 1 = não
# definida; qualquer outro erro = não deu para ler, e nada é escrito. Só o que está comprovadamente
# não definido é preenchido, em --global. Identidade que já existe nunca é trocada.
function Por-Identidade-Git {
  $exe = Onde-Esta 'git'
  if (-not $exe -or -not [System.IO.File]::Exists($exe)) { return }
  $padrao = Identidade-Git-Padrao ([string][Environment]::UserName)
  foreach ($chave in @('user.name', 'user.email')) {
    if ((Rodar-Programa $exe ('config --get ' + $chave) $env:SystemRoot) -ne 1) { continue }
    $valor = [string]$padrao[$chave]
    if (-not $valor -or $valor -match '["\\%]') { continue }
    if ((Rodar-Programa $exe ('config --global ' + $chave + ' "' + $valor + '"') $env:SystemRoot) -eq 0) {
      Write-Host "  O Git ficou com $chave = $valor. Para trocar: git config --global $chave ""outro valor"""
    }
  }
}

# Caminho absoluto para o qual um comando resolve com o PATH deste processo ('' se não resolve).
function Onde-Esta([string]$nome) {
  $c = Get-Command $nome -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return [string]$c.Source }
  return ''
}

function Pastas-Do-Path([string]$texto) {
  return @($texto -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') } | Where-Object { $_ })
}

# PATH do usuário, como está no registro (sem expandir), com o tipo do valor.
function Ler-PathUsuario {
  $r = @{ Valor = ''; Tipo = [Microsoft.Win32.RegistryValueKind]::ExpandString }
  $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  if ($null -eq $k) { return $r }
  try {
    $r.Valor = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    try { $tipo = $k.GetValueKind('Path'); if ($tipo -eq [Microsoft.Win32.RegistryValueKind]::String) { $r.Tipo = $tipo } } catch { }
  } finally { $k.Dispose() }
  return $r
}

# Regra do PATH (passo 10): o que a pessoa já tinha continua valendo. As pastas novas entram no
# FIM do PATH do usuário e do PATH deste processo, sem duplicar, e o PATH da máquina não é tocado.
# O preparo de hoje põe as pastas na frente; aqui o PATH do usuário é regravado na ordem certa.
function Acertar-Path($antes) {
  $tinha = @(Pastas-Do-Path $antes.Valor)
  $novas = New-Object System.Collections.Generic.List[string]
  $candidatas = @(Pastas-Do-Path ([string](Ler-PathUsuario).Valor)) + @((Join-Path $env:USERPROFILE '.local\bin'))
  foreach ($pasta in $candidatas) {
    $ja = $false
    foreach ($x in ($tinha + $novas.ToArray())) { if ([string]::Equals($x, $pasta, [StringComparison]::OrdinalIgnoreCase)) { $ja = $true } }
    if (-not $ja) { $novas.Add($pasta) }
  }
  if ($novas.Count -gt 0) {
    $valor = (@($antes.Valor.Trim(';')) + $novas.ToArray() | Where-Object { $_ }) -join ';'
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try { $k.SetValue('Path', $valor, $antes.Tipo) } finally { $k.Dispose() }
    [TsaNativo2]::AvisarAmbiente()
  }
  # PATH deste processo: o TSA aberto pelo script, e os terminais dele, enxergam as ferramentas na
  # hora. Conferido à parte do PATH do usuário: uma pasta pode já estar lá e faltar nesta janela.
  $exigidas = New-Object System.Collections.Generic.List[string]
  foreach ($pasta in $novas) { $exigidas.Add($pasta) }
  $exigidas.Add((Join-Path $env:USERPROFILE '.local\bin'))
  foreach ($pasta in @((Join-Path $script:I.Programas 'nodejs'), (Join-Path $script:I.Programas 'Git\cmd'))) {
    foreach ($x in @(Pastas-Do-Path ([string](Ler-PathUsuario).Valor))) { if ([string]::Equals($x, $pasta, [StringComparison]::OrdinalIgnoreCase)) { $exigidas.Add($pasta) } }
  }
  foreach ($pasta in $exigidas) {
    $meu = @(Pastas-Do-Path $env:Path)
    $ja = $false
    foreach ($x in $meu) { if ([string]::Equals($x, $pasta, [StringComparison]::OrdinalIgnoreCase)) { $ja = $true } }
    if (-not $ja) { $env:Path = $env:Path.TrimEnd(';') + ';' + $pasta }
  }
  $bash = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
  if ($bash -and -not $env:CLAUDE_CODE_GIT_BASH_PATH) { $env:CLAUDE_CODE_GIT_BASH_PATH = $bash }
}

# Política de execução que vale para uma janela nova do PowerShell (sem contar a deste processo).
function Politica-Efetiva {
  foreach ($escopo in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
    $p = [string](Get-ExecutionPolicy -Scope $escopo)
    if ($p -cne 'Undefined') { return $p }
  }
  return 'Restricted'
}

# A política de execução não muda. Com a política padrão, npm digitado no PowerShell cairia no
# atalho npm.ps1 e seria barrado. No Node que este script instalou, os três atalhos .ps1 saem, e o
# PowerShell resolve para o .cmd. Node que já existia não é tocado: só o aviso.
function Acertar-Npm([bool]$nodeNovo) {
  $pasta = Join-Path $script:I.Programas 'nodejs'
  if ($nodeNovo) {
    foreach ($nome in @('npm.ps1', 'npx.ps1', 'corepack.ps1')) {
      $arquivo = Join-Path $pasta $nome
      if ([System.IO.File]::Exists($arquivo)) { [System.IO.File]::Delete($arquivo) }
    }
    return
  }
  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($npm -and [string]$npm.CommandType -ceq 'ExternalScript' -and @('Restricted', 'AllSigned') -ccontains (Politica-Efetiva)) {
    Write-Host '  Neste computador, no PowerShell, use npm.cmd no lugar de npm.'
  }
}

# Confere para onde git, node e claude resolvem. O que já existia tem de continuar no mesmo
# caminho; o que foi instalado agora, na pasta em que foi instalado. Diferença é dita na tela;
# o script não troca a ordem do PATH para corrigir.
function Conferir-Ferramentas($antes) {
  $esperado = @{ git = (Join-Path $script:I.Programas 'Git'); node = (Join-Path $script:I.Programas 'nodejs'); claude = (Join-Path $env:USERPROFILE '.local\bin') }
  foreach ($nome in @('git', 'node', 'claude')) {
    $agora = Onde-Esta $nome
    if ($antes[$nome]) {
      if (-not [string]::Equals($agora, $antes[$nome], [StringComparison]::OrdinalIgnoreCase)) { Write-Host "  Aviso: $nome era $($antes[$nome]) e agora resolve para '$agora'." -ForegroundColor Yellow }
    } elseif (-not $agora) {
      Write-Host "  Aviso: $nome não foi instalado. O TSA foi instalado; fale com o Cadu para instalar $nome." -ForegroundColor Yellow
    } elseif (-not $agora.StartsWith($esperado[$nome].TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
      Write-Host "  Aviso: $nome resolve para $agora, fora da pasta esperada ($($esperado[$nome]))." -ForegroundColor Yellow
    } else { Feito "$nome em $agora" }
  }
}

# Código do processo filho que roda o preparo de hoje. Texto constante, sem dado nenhum. Carrega
# as funções do arquivo conferido (tudo menos a chamada final de Main) e troca duas antes de
# chamar Main: Set-ExecutionPolicy não faz nada, e o auxiliar do PATH acrescenta no FIM em vez de
# pôr na frente, já durante o preparo (o que a pessoa tinha continua valendo o tempo todo).
function Codigo-Do-Preparo {
  return @'
$t = [IO.File]::ReadAllText($env:TSA_PREREQS_ARQUIVO)
$i = $t.TrimEnd().LastIndexOf([char]10)
if ($i -lt 0 -or $t.Substring($i).Trim() -cne 'Main') { throw 'preparo em formato inesperado' }
. ([scriptblock]::Create($t.Substring(0, $i)))
function Set-ExecutionPolicy { }
function Add-UserPath([string]$pasta) {
  $alvo = $pasta.TrimEnd('\')
  $atual = [string][Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (@($atual -split ';') | Where-Object { $_.TrimEnd('\') -ieq $alvo })) {
    [Environment]::SetEnvironmentVariable('Path', ($atual.TrimEnd(';') + ';' + $pasta).TrimStart(';'), 'User')
  }
  if (-not (@($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $alvo })) { $env:Path = $env:Path.TrimEnd(';') + ';' + $pasta }
}
Main
'@
}

# Passo 10: Node LTS, Git portátil, Python e Claude Code, no perfil e sem administrador, pelas
# funções do docs/install.ps1 de hoje (TSA_ONLY_PREREQS=1; mesma fonte do comando do GitHub), sem
# duplicar a lógica aqui. Mídia fica fora (TSA_SEM_MIDIA=1). O arquivo baixado é conferido contra
# os bytes recebidos e fica preso contra troca enquanto roda (regra da seção 5.4, item 1). Aquele
# script muda a política de execução do usuário e põe as pastas na frente do PATH; aqui isso não
# pode (seção 5.1, item 7, e passo 10): ver Codigo-Do-Preparo. Ele mesmo diz o que faltou, em
# "Pendencias".
# Depois: atalhos .ps1 do Node novo, PATH no fim, conferência dos caminhos e identidade do Git.
# Falha aqui não desfaz a instalação do TSA.
function Ferramentas {
  if ($script:I.PularFerramentas) { return }
  Dizer 'Preparando as ferramentas...'
  $pathAntes = Ler-PathUsuario
  $ondeAntes = @{ git = (Onde-Esta 'git'); node = (Onde-Esta 'node'); claude = (Onde-Esta 'claude') }
  $nodeAntes = (Existe-Comprovado (Join-Path $script:I.Programas 'nodejs')) -cne 'nao'
  $preso = $null
  try {
    $r = Http-Pedir -Metodo 'GET' -Url $script:I.PrereqsUrl
    if ($r.Codigo -eq 200 -and $r.Completo -and $r.Bytes -is [byte[]] -and $r.Bytes.Length -gt 0) {
      $arquivo = Join-Path $script:I.Tmp 'prereqs.ps1'
      [System.IO.File]::WriteAllBytes($arquivo, $r.Bytes)
      $preso = Abrir-Conferido $arquivo ([long]$r.Bytes.Length) (Tsa-Sha256Hex $r.Bytes)
    }
  } catch { $preso = $null }
  if ($null -eq $preso) {
    Write-Host 'Não consegui preparar as ferramentas (Node, Git, Python e Claude Code). O TSA foi instalado. Para preparar depois, rode este comando de novo, ou fale com o Cadu.'
    return
  }
  $antes = @{ TSA_ONLY_PREREQS = $env:TSA_ONLY_PREREQS; TSA_SEM_MIDIA = $env:TSA_SEM_MIDIA; TSA_PREREQS_ARQUIVO = $env:TSA_PREREQS_ARQUIVO }
  try {
    $env:TSA_ONLY_PREREQS = '1'
    $env:TSA_SEM_MIDIA = '1'
    $env:TSA_PREREQS_ARQUIVO = $preso.Final
    # Texto de comando constante; o caminho vai por variável de ambiente (não é segredo).
    $codigo = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes((Codigo-Do-Preparo)))
    & (Caminho-PowerShell) -NoProfile -ExecutionPolicy Bypass -EncodedCommand $codigo | Out-Host
  } catch { Write-Host '  Aviso: o preparo das ferramentas parou com erro. O TSA foi instalado.' -ForegroundColor Yellow }
  finally {
    foreach ($k in @($antes.Keys)) { [Environment]::SetEnvironmentVariable($k, $antes[$k]) }
    try { $preso.Fluxo.Dispose() } catch { }
  }
  try { Acertar-Path $pathAntes } catch { Write-Host '  Aviso: não consegui acertar o PATH do usuário.' -ForegroundColor Yellow }
  try { Acertar-Npm (-not $nodeAntes -and [System.IO.Directory]::Exists((Join-Path $script:I.Programas 'nodejs'))) } catch { Write-Host '  Aviso: não consegui acertar os atalhos do npm.' -ForegroundColor Yellow }
  try { Conferir-Ferramentas $ondeAntes } catch { Write-Host '  Aviso: não consegui conferir as ferramentas.' -ForegroundColor Yellow }
  try { Por-Identidade-Git } catch { Write-Host '  Aviso: não consegui conferir a identidade do Git.' -ForegroundColor Yellow }
  Write-Host '  Janela do PowerShell que já estava aberta só enxerga as ferramentas depois de fechada e aberta de novo.'
}

function Abrir-Tsa {
  try { Start-Process -FilePath $script:I.AppExe } catch { }
}

function Criar-Tmp {
  $script:I.Tmp = Join-Path $script:I.TmpRaiz ([guid]::NewGuid().ToString('N'))
  [void][System.IO.Directory]::CreateDirectory($script:I.Tmp)
}

function Instalar-Novo {
  # Só instala com o estado do atualizador ausente ou com "troca": null. Estado que não dá para
  # ler pode esconder uma troca interrompida, e aí a pasta do app está fora do lugar só por isso.
  $troca = Ler-Troca
  if ($troca -cne 'ausente' -and $troca -cne 'null') { Parar 'Há uma atualização interrompida. Fale com o Cadu.' }
  # Passo 1.
  Conferir-ControleInteligente
  if ($script:I.Caso -ceq 'A') {
    Pedir-Convite
    Perguntar-Setor
  } else {
    Dizer 'TSA cadastrado e sem o app: reinstalando.'
    if (-not [System.IO.File]::Exists($script:I.PerfilJson)) { Perguntar-Setor }
  }
  Write-Host "O instalador do TSA não mostra a tela azul 'O Windows protegeu o computador'. Se ela aparecer, não clique em 'Executar assim mesmo': feche e fale com o Cadu."
  Criar-Tmp
  # Passos 2 e 3.
  Conferir-Manifesto (Pedir-Manifesto)
  # Passos 4 e 5.
  $exe = Baixar-Artefato
  Dizer 'Conferindo o arquivo...'
  $script:I.ExeAberto = Abrir-Conferido $exe $script:I.M.Bytes $script:I.M.Sha
  if ($null -eq $script:I.ExeAberto) {
    try { [System.IO.File]::Delete($exe) } catch { }
    Parar $script:I.FraseFalha
  }
  Feito 'Tamanho e SHA-256 conferidos'
  # Passos 7 a 10.
  Instalar
  Gravar-Perfil
  Marca-Agendador
  if ($script:I.Caso -ceq 'A') { Entregar-Convite }
  Ferramentas
  Abrir-Tsa
  Write-Host ''
  if ($script:I.Caso -ceq 'A') { Write-Host 'O TSA vai abrir e terminar o cadastro sozinho.' }
  else { Write-Host 'O TSA foi reinstalado e vai abrir.' }
}

function Limpar {
  if (-not (Get-Variable -Name I -Scope Script -ErrorAction SilentlyContinue)) { return }
  if ($null -ne $script:I.Convite) { try { $script:I.Convite.Dispose() } catch { }; $script:I.Convite = $null }
  Fechar-Exe
  Soltar-Trava
  if ($script:I.Tmp) {
    try { if ([System.IO.Directory]::Exists($script:I.Tmp)) { [System.IO.Directory]::Delete($script:I.Tmp, $true) } } catch { }
    try { if ([System.IO.Directory]::Exists($script:I.TmpRaiz) -and @([System.IO.Directory]::GetFileSystemEntries($script:I.TmpRaiz)).Count -eq 0) { [System.IO.Directory]::Delete($script:I.TmpRaiz) } } catch { }
  }
}

# Recusas, recuperações e o caso. O resultado fica em $script:I.Rc (0 só quando terminou bem).
function Rodar-Casos {
  Conferir-Ambiente
  Carregar-Nativo
  # A classificação recomeça do zero quando outra execução termina enquanto esta espera a trava.
  for ($volta = 1; $true; $volta++) {
    Retomar-Troca
    if ((Recuperar-Primeira) -ne $true) { break }
    if ($volta -ge 3) { Parar 'Há outra instalação em andamento. Espere terminar e rode o comando de novo.' }
  }
  $script:I.Caso = Classificar
  if ($script:I.Caso -ceq 'B1') { Caso-B1; $script:I.Rc = 0; return }
  if ($script:I.Caso -ceq 'B2') {
    if ($script:I.ConviteNaoEntregue) { Write-Host 'O TSA já está instalado. Abra o TSA e cole o seu convite na tela de cadastro.' }
    else { Write-Host 'Este computador já tem o TSA. Abra o TSA: ele termina o cadastro e passa a se atualizar sozinho.' }
    $script:I.Rc = 0
    return
  }
  if ($script:I.Caso -ceq 'D') {
    # Classificar deixa a pasta em RegistroPasta só quando a instalação de fora foi identificada.
    [void](Ler-Registro)
    if ($script:I.RegistroPasta) {
      Write-Host "Este computador já tem um TSA instalado em outra pasta ($($script:I.RegistroPasta)). Feche o TSA, desinstale-o em Configurações → Aplicativos → Aplicativos instalados e rode este comando de novo. Seus projetos e conversas não são apagados. Na dúvida, fale com o Cadu."
    } else {
      Write-Host 'O registro do TSA neste computador está diferente do esperado. Não desinstale nada. Fale com o Cadu.'
    }
    return
  }
  if ($script:I.Caso -cne 'A' -and $script:I.Caso -cne 'C') { Parar 'Não consegui entender o estado deste computador. Fale com o Cadu.' }
  Instalar-Novo
  $script:I.Rc = 0
}

function Main {
  param([string]$Perfil = '', [bool]$SemAgendador = $false)
  # Antes de tudo: num PowerShell restrito, nem a linha do TLS roda.
  if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'Este computador restringe o PowerShell. Fale com o Cadu.'
    $global:LASTEXITCODE = 1
    return
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version 2.0
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
  $script:I = Novo-Estado
  $rc = 1
  try {
    if ($Perfil) {
      if ($script:I.Perfis -cnotcontains $Perfil) { Parar ('-Perfil aceita: ' + ($script:I.Perfis -join ', ')) }
      $script:I.Perfil = $Perfil
    }
    $script:I.SemAgendador = $SemAgendador
    Rodar-Casos | Out-Null
    if ($script:I.Rc -is [int] -and $script:I.Rc -eq 0) { $rc = 0 }
  } catch {
    $rc = 1
    if ($script:I.Parada) { Write-Host $script:I.Parada -ForegroundColor Red }
    else {
      Write-Host ('Erro inesperado: ' + $_.Exception.Message) -ForegroundColor Red
      Write-Host 'Fale com o Cadu.' -ForegroundColor Red
    }
  } finally {
    Limpar
  }
  $global:LASTEXITCODE = $rc
}

Main -Perfil $Perfil -SemAgendador ([bool]$SemAgendador)
