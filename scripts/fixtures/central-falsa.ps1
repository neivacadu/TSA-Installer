# Central falsa para scripts/test-instalartsa.ps1 (Windows). So ASCII: roda por -File.
# Responde em http://localhost:<Porta>/ as rotas que o install.ps1 chama:
#   POST /apptsa/api/convite/validar
#   POST /apptsa/api/release/nova-instalacao      GET /inteligencia/v1/app/release
#   GET  /apptsa/api/artefatos/<sha256>           GET /inteligencia/v1/app/artefatos/<sha256>
# O que responder vem de <Pasta>\cfg.json, lido a cada pedido. Cada pedido vira uma linha em
# <Pasta>\log.jsonl. Convite e credencial nunca sao gravados: so o SHA-256 de cada um.
param([Parameter(Mandatory = $true)][int]$Porta, [Parameter(Mandatory = $true)][string]$Pasta)
$ErrorActionPreference = 'Stop'

function Sha([string]$texto) {
  $h = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
  try { return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto))) -replace '-', '').ToLowerInvariant() }
  finally { $h.Dispose() }
}

function Responder($res, [int]$codigo, [string]$corpo) {
  $res.StatusCode = $codigo
  if ($corpo) {
    $b = [Text.Encoding]::UTF8.GetBytes($corpo)
    $res.ContentType = 'application/json'
    $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length)
  }
  $res.Close()
}

$escuta = New-Object System.Net.HttpListener
$escuta.Prefixes.Add("http://localhost:$Porta/")
$escuta.Start()
$cenario = ''
$conta = @{}
while ($escuta.IsListening) {
  $ctx = $escuta.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    $caminho = $req.Url.AbsolutePath
    if ($caminho -eq '/parar') { Responder $res 200 '{"ok":true}'; break }
    if ($caminho -eq '/saude') { Responder $res 200 '{"ok":true}'; continue }
    $cfg = [IO.File]::ReadAllText((Join-Path $Pasta 'cfg.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($cfg.id -ne $cenario) { $cenario = $cfg.id; $conta = @{} }
    $corpo = ''
    if ($req.HasEntityBody) {
      $leitor = New-Object System.IO.StreamReader ($req.InputStream, [Text.Encoding]::UTF8)
      $corpo = $leitor.ReadToEnd()
    }
    $reg = [ordered]@{ id = $cenario; metodo = $req.HttpMethod; caminho = $caminho; consulta = $req.Url.Query
      range = [string]$req.Headers['Range']; tipo = [string]$req.ContentType; convite_cabecalho = ''; autorizacao = ''; corpo_convite = ''; corpo = '' }
    if ($req.Headers['X-TSA-Convite']) { $reg.convite_cabecalho = Sha $req.Headers['X-TSA-Convite'] }
    if ($req.Headers['Authorization']) {
      $a = [string]$req.Headers['Authorization']
      if ($a.StartsWith('Bearer ')) { $reg.autorizacao = Sha $a.Substring(7) } else { $reg.autorizacao = 'sem-bearer' }
    }
    if ($corpo -match '"convite":"([^"]*)"') {
      $reg.corpo_convite = Sha $Matches[1]
      $reg.corpo = $corpo.Replace($Matches[1], '<convite>')
    } else { $reg.corpo = $corpo }
    [IO.File]::AppendAllText((Join-Path $Pasta 'log.jsonl'), (($reg | ConvertTo-Json -Compress) + "`n"))

    if ($caminho -match '/convite/validar$') {
      $n = [int]$conta['validar']; $conta['validar'] = $n + 1
      $codigos = @($cfg.validar)
      $codigo = [int]$codigos[[Math]::Min($n, $codigos.Count - 1)]
      if ($codigo -eq 200) {
        $sug = 'null'
        if ($cfg.perfil_sugerido) { $sug = '"' + $cfg.perfil_sugerido + '"' }
        Responder $res 200 ('{"valido":true,"expira_em":"2026-10-07T14:00:00Z","perfil_sugerido":' + $sug + '}')
      }
      elseif ($codigo -eq 410) { Responder $res 410 ('{"error":"' + $cfg.erro410 + '"}') }
      else { Responder $res $codigo '{"error":"convite_invalido"}' }
      continue
    }
    if ($caminho -match '/release/nova-instalacao$' -or $caminho -match '/v1/app/release$') {
      $n = [int]$conta['release']; $conta['release'] = $n + 1
      if ([int]$cfg.release -ne 200) { Responder $res ([int]$cfg.release) ''; continue }
      $arquivo = $cfg.manifesto
      if ($n -ge 1 -and $cfg.manifesto2) { $arquivo = $cfg.manifesto2 }
      $m = [IO.File]::ReadAllText($arquivo, [Text.Encoding]::UTF8)
      Responder $res 200 ('{"manifesto":' + $m + ',"origem":"ativa","teste":false}')
      continue
    }
    if ($caminho -match '/artefatos/[0-9a-f]{64}$') {
      $n = [int]$conta['artefato']; $conta['artefato'] = $n + 1
      if ($cfg.artefato_codigo -and [int]$cfg.artefato_codigo -ne 200) { Responder $res ([int]$cfg.artefato_codigo) '{"error":"artifact_not_found"}'; continue }
      $bytes = [IO.File]::ReadAllBytes($cfg.artefato)
      $inicio = 0
      if ($req.Headers['Range'] -match '^bytes=([0-9]+)-$') { $inicio = [int]$Matches[1] }
      if ($inicio -ge $bytes.Length -and $inicio -gt 0) {
        $res.StatusCode = 416; $res.AddHeader('Content-Range', "bytes */$($bytes.Length)"); $res.Close(); continue
      }
      $res.ContentType = 'application/octet-stream'
      if ($inicio -gt 0) {
        $res.StatusCode = 206
        $res.AddHeader('Content-Range', "bytes $inicio-$($bytes.Length - 1)/$($bytes.Length)")
      } else { $res.StatusCode = 200 }
      $res.ContentLength64 = $bytes.Length - $inicio
      if ($cfg.corte -and $n -eq 0) {
        # A primeira transferencia cai na metade.
        $metade = [int]($bytes.Length / 2)
        $res.OutputStream.Write($bytes, 0, $metade)
        $res.OutputStream.Flush()
        Start-Sleep -Milliseconds 300
        $res.Abort()
        continue
      }
      if ($cfg.parada -and $n -eq 0) {
        # A primeira transferencia para na metade e fica sem mandar nada.
        $metade = [int]($bytes.Length / 2)
        $res.OutputStream.Write($bytes, 0, $metade)
        $res.OutputStream.Flush()
        Start-Sleep -Seconds ([int]$cfg.parada)
        $res.Abort()
        continue
      }
      $res.OutputStream.Write($bytes, $inicio, $bytes.Length - $inicio)
      $res.Close()
      continue
    }
    Responder $res 404 '{"error":"not_found"}'
  } catch {
    try { [IO.File]::AppendAllText((Join-Path $Pasta 'erros.txt'), ($_ | Out-String)) } catch { }
    try { $res.Abort() } catch { }
  }
}
$escuta.Stop()
