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

Write-Host "`n== ParamHash / ParamValue / Unescape-Safe ==" -ForegroundColor Cyan

$ph = ConvertTo-ParamHashtable -Params 'security=tls&type=ws&sni=example.com'
Assert-Equal $ph['security'] 'tls' 'ParamHash security'
Assert-Equal $ph['type'] 'ws' 'ParamHash type'
Assert-Equal $ph['sni'] 'example.com' 'ParamHash sni'
Assert-Equal ((ConvertTo-ParamHashtable -Params '').Count) 0 'ParamHash vazio'
Assert-Equal (Get-ParamValue $ph 'type') 'ws' 'ParamValue presente'
Assert-Equal (Get-ParamValue $ph 'missing' 'def') 'def' 'ParamValue default'
Assert-Equal (Unescape-Safe 'a%20b') 'a b' 'Unescape-Safe decodifica'

Write-Host "`n== Get-ShortName ==" -ForegroundColor Cyan

Assert-Equal (Get-ShortName -Name 'curto') 'curto' 'ShortName curto'
Assert-Equal (Get-ShortName -Name '') '' 'ShortName vazio'
$longName = ('x' * 40)
$sn = Get-ShortName -Name $longName
Assert-True ($sn.Length -le 26) 'ShortName longo trunca (<=26)'
Assert-True ($sn.EndsWith('...')) 'ShortName termina com ...'

Write-Host "`n== Test-CloudflareIp ==" -ForegroundColor Cyan

Assert-True (Test-CloudflareIp -IpString '104.16.5.6') 'Cloudflare 104.16.x'
Assert-True (Test-CloudflareIp -IpString '104.31.255.255') 'Cloudflare 104.31.x'
Assert-True (Test-CloudflareIp -IpString '172.64.1.1') 'Cloudflare 172.64.x'
Assert-True (Test-CloudflareIp -IpString '172.71.1.1') 'Cloudflare 172.71.x'
Assert-True (Test-CloudflareIp -IpString '162.159.1.1') 'Cloudflare 162.159.x'
Assert-True (Test-CloudflareIp -IpString '173.245.1.1') 'Cloudflare 173.245.x'
Assert-True (Test-CloudflareIp -IpString '141.101.1.1') 'Cloudflare 141.101.x'
Assert-True (Test-CloudflareIp -IpString '188.114.1.1') 'Cloudflare 188.114.x'
Assert-True (Test-CloudflareIp -IpString '190.93.1.1') 'Cloudflare 190.93.x'
Assert-True (Test-CloudflareIp -IpString '197.234.1.1') 'Cloudflare 197.234.x'
Assert-True (Test-CloudflareIp -IpString '198.41.1.1') 'Cloudflare 198.41.x'
Assert-True (-not (Test-CloudflareIp -IpString '8.8.8.8')) 'Nao-cloudflare 8.8.8.8'
Assert-True (-not (Test-CloudflareIp -IpString '1.2.3.4')) 'Nao-cloudflare 1.2.3.4'

Write-Host "`n== New-StreamSettings (transports) ==" -ForegroundColor Cyan

$stTcp = New-StreamSettings -P @{}
Assert-Equal $stTcp.network 'tcp' 'Stream tcp default network'
Assert-Equal $stTcp.security 'none' 'Stream tcp default security'

$stTls = New-StreamSettings -P @{ security = 'tls'; sni = 'example.com'; alpn = 'h2,http/1.1'; fp = 'chrome' }
Assert-Equal $stTls.security 'tls' 'Stream tls security'
Assert-Equal $stTls['tlsSettings']['serverName'] 'example.com' 'Stream tls sni'
Assert-Equal ($stTls['tlsSettings']['alpn'] -join ',') 'h2,http/1.1' 'Stream tls alpn'
Assert-Equal $stTls['tlsSettings']['fingerprint'] 'chrome' 'Stream tls fp'

$stRl = New-StreamSettings -P @{ security = 'reality'; sni = 'x'; pbk = 'y'; sid = 'z'; fp = 'chrome'; spx = '/' }
Assert-Equal $stRl.security 'reality' 'Stream reality security'
Assert-Equal $stRl['realitySettings']['publicKey'] 'y' 'Stream reality pbk'
Assert-Equal $stRl['realitySettings']['shortId'] 'z' 'Stream reality sid'

$stWs = New-StreamSettings -P @{ type = 'ws'; path = '/x'; host = 'h' }
Assert-Equal $stWs.network 'ws' 'Stream ws network'
Assert-Equal $stWs['wsSettings']['path'] '/x' 'Stream ws path'
Assert-Equal $stWs['wsSettings']['headers']['Host'] 'h' 'Stream ws host'

$stGrpc = New-StreamSettings -P @{ type = 'grpc'; serviceName = 'svc' }
Assert-Equal $stGrpc.network 'grpc' 'Stream grpc network'
Assert-Equal $stGrpc['grpcSettings']['serviceName'] 'svc' 'Stream grpc serviceName'

$stXh = New-StreamSettings -P @{ type = 'xhttp'; path = '/'; host = 'h'; mode = 'auto' }
Assert-Equal $stXh.network 'xhttp' 'Stream xhttp network'
Assert-Equal $stXh['xhttpSettings']['mode'] 'auto' 'Stream xhttp mode'

Write-Host "`n== Filtro vmess (Test-ConfigStable) ==" -ForegroundColor Cyan

Assert-True (Test-ConfigStable -Config @{ Protocol = 'vmess'; Network = 'tcp'; Host = 'x.com' }) 'vmess+tcp aceito'
Assert-True (-not (Test-ConfigStable -Config @{ Protocol = 'vmess'; Network = 'ws'; Host = 'x.com' })) 'vmess+ws rejeitado'

Write-Host "`n== Geracao de config (trojan/ss/vmess) ==" -ForegroundColor Cyan

$trojanCfg = @{ Protocol = 'trojan'; Host = '1.2.3.4'; Port = 443; Password = 'pw'; Params = ''; Name = 't'; Ping = 50 }
Assert-True (Generate-V2RayConfig -Config $trojanCfg -Tun $false) 'Gera trojan (retorno true)'
$jsonTj = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonTj.outbounds[0].protocol 'trojan' 'Trojan protocol'
Assert-Equal $jsonTj.outbounds[0].streamSettings.security 'tls' 'Trojan forca tls'

$ssBad = @{ Protocol = 'shadowsocks'; Host = '1.2.3.4'; Port = 8388; Method = 'unknown'; Password = 'p'; Params = ''; Name = 's'; Ping = 50 }
Assert-True (-not (Generate-V2RayConfig -Config $ssBad -Tun $false)) 'ss metodo desconhecido -> rejeita'

$ssWs = @{ Protocol = 'shadowsocks'; Host = '1.2.3.4'; Port = 8388; Method = 'aes-256-gcm'; Password = 'p'; Params = 'type=ws'; Name = 's'; Ping = 50 }
Assert-True (-not (Generate-V2RayConfig -Config $ssWs -Tun $false)) 'ss com transport ws -> rejeita'

$vmessWs = @{ Protocol = 'vmess'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; AlterID = 0; Security = 'auto'; Network = 'ws'; Params = ''; Name = 'v'; Ping = 50 }
Assert-True (-not (Generate-V2RayConfig -Config $vmessWs -Tun $false)) 'vmess+ws -> rejeita'

$vmessTcp = @{ Protocol = 'vmess'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; AlterID = 0; Security = 'auto'; Network = 'tcp'; Params = ''; Name = 'v'; Ping = 50 }
Assert-True (Generate-V2RayConfig -Config $vmessTcp -Tun $false) 'vmess+tcp gera (retorno true)'
$jsonVm = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonVm.outbounds[0].protocol 'vmess' 'VMess protocol'
Assert-Equal $jsonVm.outbounds[0].streamSettings.network 'tcp' 'VMess network tcp'

Write-Host "`n== Geracao de config com portas customizadas (scan paralelo) ==" -ForegroundColor Cyan

$scanCfgPath = Join-Path $Script:TempDir 'config-scan-custom.json'
Assert-True (Generate-V2RayConfig -Config $vlessCfg -Tun $false -SocksPort 10818 -HttpPort 10819 -ConfigPath $scanCfgPath) 'Gera config com porta custom (retorno true)'
$jsonScan = Get-Content $scanCfgPath -Raw | ConvertFrom-Json
$socksIn = @($jsonScan.inbounds | Where-Object { $_.protocol -eq 'socks' })[0]
$httpIn = @($jsonScan.inbounds | Where-Object { $_.protocol -eq 'http' })[0]
Assert-Equal $socksIn.port 10818 'Config scan: socks na porta custom'
Assert-Equal $httpIn.port 10819 'Config scan: http na porta custom'
Assert-True (Test-Path $scanCfgPath) 'Config scan: arquivo gravado no caminho custom'

Write-Host ''
Write-Host "Resultado: $($script:Pass) passaram, $($script:Fail) falharam"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
