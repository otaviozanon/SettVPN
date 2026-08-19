# ============================================================
# Testes unitarios SettVPN (offline, sem rede / sem v2ray)
# Roda:  powershell -NoProfile -ExecutionPolicy Bypass -File Tests\unit-tests.ps1
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$fullPs1 = Join-Path $root 'Core\SettVPN_Full.ps1'

# Extrai apenas as definicoes de funcao (sem rodar o entry point / GUI)
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPs1, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Host 'ERROS DE PARSE em SettVPN_Full.ps1:' -ForegroundColor Red
    $errs | ForEach-Object { Write-Host ("  " + $_.Message) -ForegroundColor Red }
    exit 1
}
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$funcSource = ($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
Invoke-Expression $funcSource

$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ($Actual -eq $Expected) {
        $script:Pass++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host "[FAIL] $Name (esperado '$Expected', obtido '$Actual')" -ForegroundColor Red
    }
}

function Assert-True {
    param($Cond, [string]$Name)
    if ($Cond) {
        $script:Pass++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }
}

Write-Host "`n== Bug 1: contagem regressiva (ETA adaptativo) ==" -ForegroundColor Cyan

Assert-Equal (Get-ScanEtaSeconds -ElapsedSeconds 150 -Total 25 -Tested 5) 600.0 "ETA 25 serv, 5 testados em 150s -> 20 * 30s = 600"
Assert-Equal (Get-ScanEtaSeconds -ElapsedSeconds 100 -Total 10 -Tested 10) 0.0 "Todos testados -> ETA 0"
Assert-Equal (Get-ScanEtaSeconds -ElapsedSeconds 0 -Total 10 -Tested 0) 0.0 "Nenhum testado -> ETA 0"
Assert-Equal (Get-ScanEtaSeconds -ElapsedSeconds 30 -Total 25 -Tested 1) 720.0 "1 servidor em 30s -> 24 * 30s = 720"

$deadline = [DateTime]::Now.AddSeconds(100)
$r0 = Get-ScanRemainingSeconds -Deadline $deadline
Assert-True ($r0 -ge 99 -and $r0 -le 100) "Deadline +100s -> restante ~100 (obtido $r0)"
Assert-Equal (Get-ScanRemainingSeconds -Deadline ([DateTime]::Now.AddSeconds(-5))) 0 "Deadline no passado -> 0"
Assert-Equal (Get-ScanRemainingSeconds -Deadline ([DateTime]::MinValue)) 0 "Sem deadline -> 0"

$d1 = Get-ScanRemainingSeconds -Deadline $deadline
Start-Sleep -Milliseconds 1100
$d2 = Get-ScanRemainingSeconds -Deadline $deadline
Assert-True ($d2 -le $d1) "Restante desce com o tempo ($d1 -> $d2)"
Assert-True (($d1 - $d2) -ge 0 -and ($d1 - $d2) -le 2) "Cai ~1s por segundo (delta = $($d1 - $d2))"

Write-Host "`n== Bug 4: mapeamento de pais ==" -ForegroundColor Cyan

Assert-Equal (Get-CountryNamePt -Code 'BR') 'Brasil' 'Pais BR -> Brasil'
Assert-Equal (Get-CountryNamePt -Code 'US') 'Estados Unidos' 'Pais US -> Estados Unidos'
Assert-Equal (Get-CountryNamePt -Code 'FR') 'Franca' 'Pais FR -> Franca'
Assert-Equal (Get-CountryNamePt -Code 'RU') 'Russia' 'Pais RU -> Russia'
Assert-Equal (Get-CountryNamePt -Code 'DE') 'Alemanha' 'Pais DE -> Alemanha'
Assert-Equal (Get-CountryNamePt -Code '') '' 'Codigo vazio -> vazio'
Assert-Equal (Get-CountryNamePt -Code 'ZZ') 'ZZ' 'Codigo desconhecido -> retorna o proprio codigo'
Assert-Equal (Get-CountryCodeFromName -Name 'US_speednode_0123') 'US' 'Inferencia de pais pelo nome (US)'
Assert-Equal (Get-CountryCodeFromName -Name '??+CloudFlare??') '' 'Nome sem codigo -> vazio'
Assert-Equal (Get-CountryCodeFromName -Name 'VPS-BR-01') 'BR' 'Inferencia pelo nome (BR)'

Write-Host "`n== Parse de configs ==" -ForegroundColor Cyan

$vl = Parse-VlessConfig -Uri 'vless://123e4567-e89b-12d3-a456-426614174000@1.2.3.4:443?security=tls&type=ws#Server BR'
Assert-Equal $vl.Protocol 'vless' 'Parse vless protocolo'
Assert-Equal $vl.Host '1.2.3.4' 'Parse vless host'
Assert-Equal $vl.Port 443 'Parse vless porta'
Assert-Equal $vl.Name 'Server BR' 'Parse vless nome'

$vl2 = Parse-VlessConfig -Uri 'vless://not-a-uuid@1.2.3.4:443#Bad'
Assert-Equal $vl2 $null 'Parse vless com UUID invalido -> null'

$ssB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('aes-256-gcm:password123'))
$ss = Parse-ShadowsocksConfig -Uri ('ss://' + $ssB64 + '@2.3.4.5:8388#SS-Node')
Assert-Equal $ss.Protocol 'shadowsocks' 'Parse ss protocolo'
Assert-Equal $ss.Method 'aes-256-gcm' 'Parse ss metodo'

Write-Host "`n== Filtro de estabilidade (Test-ConfigStable) ==" -ForegroundColor Cyan

Assert-True (-not (Test-ConfigStable -Config @{ Params = 'type=grpc'; Host = 'x.com' })) 'Rejeita transport grpc'
Assert-True (-not (Test-ConfigStable -Config @{ Params = 'type=xhttp'; Host = 'x.com' })) 'Rejeita transport xhttp'
Assert-True (Test-ConfigStable -Config @{ Params = 'security=reality'; Host = 'x.com' }) 'Aceita security reality (Xray suporta)'
Assert-True (Test-ConfigStable -Config @{ Params = 'type=ws&security=tls'; Host = 'example.com' }) 'Aceita ws + tls'
Assert-True (Test-ConfigStable -Config @{ Params = ''; Host = '104.16.1.1' }) 'Aceita IP Cloudflare (teste de tunel decide)'

Write-Host "`n== Geracao de config TUN (modo TUN) ==" -ForegroundColor Cyan

$Script:TempDir = Join-Path $env:TEMP 'SettVPN-unit'
New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
$Script:ConfigJson = Join-Path $Script:TempDir 'config-test.json'
$Script:XrayLog = Join-Path $Script:TempDir 'xray-test.log'
$Script:V2RayExe = Join-Path $Script:TempDir 'v2ray.exe'
$Script:WintunDll = Join-Path $Script:TempDir 'wintun.dll'
$vlessCfg = @{ Protocol = 'vless'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; Params = ''; Name = 'test'; Ping = 50 }

Assert-True (Generate-V2RayConfig -Config $vlessCfg -Tun $true) 'Gera config com TUN (retorno true)'
$jsonTun = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
$tunInbound = @($jsonTun.inbounds | Where-Object { $_.protocol -eq 'tun' })[0]
Assert-True ($null -ne $tunInbound) 'Config TUN contem inbound protocol=tun'
Assert-True ($null -ne $tunInbound.settings.autoSystemRoutingTable) 'Config TUN tem autoSystemRoutingTable (roteia tudo)'
Assert-True ($null -ne $tunInbound.settings.autoOutboundsInterface) 'Config TUN tem autoOutboundsInterface (evita loop)'

Assert-True (Generate-V2RayConfig -Config $vlessCfg -Tun $false) 'Gera config sem TUN (retorno true)'
$jsonNoTun = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
$noTun = @($jsonNoTun.inbounds | Where-Object { $_.protocol -eq 'tun' }).Count -eq 0
Assert-True $noTun 'Config sem TUN nao contem inbound tun'

Write-Host ''
Write-Host "Resultado: $($script:Pass) passaram, $($script:Fail) falharam"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
