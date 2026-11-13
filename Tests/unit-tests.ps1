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

# Servidores de menor ping (CDN) costumam estar mortos: amostra precisa se espalhar.
$spreadAll = @(Get-SpreadSample -Items @(1, 2, 3) -Max 12)
Assert-Equal $spreadAll.Count 3 'Amostra: lista menor que o limite volta inteira'
$spread = @(Get-SpreadSample -Items @(1..100) -Max 10)
Assert-Equal $spread.Count 10 'Amostra: limita ao Max'
Assert-Equal $spread[0] 1 'Amostra: comeca no primeiro'
Assert-True ($spread[1] -ge 10) 'Amostra: espalha em vez de pegar o topo'
Assert-Equal @(Get-SpreadSample -Items @() -Max 5).Count 0 'Amostra: lista vazia volta vazia'

# Ping da tela: usa a latencia real (dentro do tunel) e cai no TCP so quando nao existe.
Assert-Equal (Get-ServerPingMs -Config @{ Ping = 12; RealPing = 340 }) 340 'Ping: prefere latencia real'
Assert-Equal (Get-ServerPingMs -Config @{ Ping = 12; RealPing = 9999 }) 12 'Ping: 9999 (medida falhou) cai no TCP'
Assert-Equal (Get-ServerPingMs -Config @{ Ping = 12; RealPing = 0 }) 12 'Ping: zero invalido cai no TCP'
Assert-Equal (Get-ServerPingMs -Config @{ Ping = 12 }) 12 'Ping: sem RealPing usa TCP'

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

$vmessOk = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"v":"2","ps":"good","add":"1.2.3.4","port":"443","id":"123e4567-e89b-12d3-a456-426614174000","aid":"0","net":"tcp","type":"none","scy":"auto"}'))
$vm = Parse-VmessConfig -Uri ('vmess://' + $vmessOk)
Assert-Equal $vm.Protocol 'vmess' 'Parse vmess protocolo'
Assert-Equal $vm.UUID '123e4567-e89b-12d3-a456-426614174000' 'Parse vmess uuid'

$vmessBad = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"v":"2","ps":"bad","add":"1.2.3.4","port":"443","id":"not-a-uuid","aid":"0","net":"tcp","type":"none","scy":"auto"}'))
Assert-Equal (Parse-VmessConfig -Uri ('vmess://' + $vmessBad)) $null 'Parse vmess com UUID invalido -> null'

Write-Host "`n== Parse de configs: IPv6, SS SIP002/legado, VMess minimo ==" -ForegroundColor Cyan

$vl6 = Parse-VlessConfig -Uri 'vless://123e4567-e89b-12d3-a456-426614174000@[2001:db8::1]:443?security=tls#IPv6'
Assert-Equal $vl6.Host '2001:db8::1' 'Parse vless IPv6 (brackets removidos)'
Assert-Equal $vl6.Port 443 'Parse vless IPv6 porta'

$tj6 = Parse-TrojanConfig -Uri 'trojan://pw@[2001:db8::2]:443#IPv6T'
Assert-Equal $tj6.Host '2001:db8::2' 'Parse trojan IPv6'
Assert-Equal $tj6.Port 443 'Parse trojan IPv6 porta'

$cred = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('chacha20-ietf-poly1305:pass')).Replace('+', '-').Replace('/', '_').TrimEnd('=')
$ssSip = Parse-ShadowsocksConfig -Uri ("ss://$cred@2.3.4.5:8388#SIP002")
Assert-Equal $ssSip.Method 'chacha20-ietf-poly1305' 'SS SIP002 base64url metodo'
Assert-Equal $ssSip.Password 'pass' 'SS SIP002 senha'

$legacy = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('aes-128-gcm:pw@2.3.4.6:8389')).Replace('+', '-').Replace('/', '_').TrimEnd('=')
$ssOld = Parse-ShadowsocksConfig -Uri ("ss://$legacy#Legacy")
Assert-Equal $ssOld.Host '2.3.4.6' 'SS legado host'
Assert-Equal $ssOld.Port 8389 'SS legado porta'

$ssPlain = Parse-ShadowsocksConfig -Uri 'ss://aes-256-gcm:pw@2.3.4.7:8388#Plain'
Assert-Equal $ssPlain.Method 'aes-256-gcm' 'SS userinfo em texto puro'

$vmMin = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"v":"2","add":"5.6.7.8","port":"443","id":"123e4567-e89b-12d3-a456-426614174000"}'))
$vm2 = Parse-VmessConfig -Uri ('vmess://' + $vmMin)
Assert-Equal $vm2.AlterID 0 'VMess sem aid -> 0'
Assert-Equal $vm2.Network 'tcp' 'VMess sem net -> tcp'
Assert-Equal $vm2.Name '5.6.7.8' 'VMess sem ps -> host'
Assert-Equal $vm2.Security 'auto' 'VMess sem scy -> auto'

$k1 = Get-ConfigKey -Config @{ Protocol = 'vless'; Host = 'h.com'; Port = 443; UUID = 'a'; Password = ''; Method = ''; Network = ''; Params = '' }
$k2 = Get-ConfigKey -Config @{ Protocol = 'vless'; Host = 'h.com'; Port = 443; UUID = 'b'; Password = ''; Method = ''; Network = ''; Params = '' }
Assert-True ($k1 -ne $k2) 'Get-ConfigKey separa mesmo host:porta com UUIDs diferentes'
Assert-True ((Get-ConfigKey -Config @{ Protocol = 'shadowsocks'; Host = 'h.com'; Port = 1; Password = 'p'; Method = 'aes-256-gcm' }) -match 'shadowsocks') 'Get-ConfigKey aceita SS sem chave UUID'

$freePort = Get-FreePort -Start 19950
Assert-True ($freePort -ge 19950 -and $freePort -lt 20150) 'Get-FreePort retorna porta na faixa pedida'
$freePort2 = Get-FreePort -Start 19950 -Exclude @($freePort)
Assert-True ($freePort2 -ne $freePort) 'Get-FreePort respeita Exclude'

$po = New-ProxyOverride -Current '*.corp.com'
Assert-True ($po -match '\*\.corp\.com') 'Proxy override mantem bypass existente'
Assert-True ($po -match 'localhost') 'Proxy override adiciona localhost'
Assert-True ($po -match '127\.\*') 'Proxy override adiciona 127.*'
$poCount = @((New-ProxyOverride -Current 'localhost;127.*;<local>') -split ';' | Where-Object { $_ -eq 'localhost' }).Count
Assert-Equal $poCount 1 'Proxy override nao duplica entradas'

$lp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$lp.Start()
$lpPort = [int]$lp.LocalEndpoint.Port
Assert-True (Test-LocalPort -Port $lpPort -TimeoutMs 1000) 'Test-LocalPort detecta porta aberta'
$lp.Stop()
Assert-True (-not (Test-LocalPort -Port $lpPort -TimeoutMs 300)) 'Test-LocalPort detecta porta fechada'

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
$boltName = [string][char]0x26A1 + ' Fast 1'
Assert-Equal (Get-ShortName -Name $boltName) 'Fast 1' 'ShortName remove emoji'
$flagName = [char]::ConvertFromUtf32(0x1F1E7) + [char]::ConvertFromUtf32(0x1F1F7) + ' BR-1 #2'
Assert-Equal (Get-ShortName -Name $flagName) 'BR-1 #2' 'ShortName remove bandeira (surrogate)'
$cnName = [string][char]0x7F8E + [char]0x56FD + '2@ripaojiedian'
Assert-Equal (Get-ShortName -Name $cnName) ($cnName.Split('@')[0]) 'ShortName remove sufixo @provedor'
$hkName = [string][char]0x9999 + [char]0x6E2F + '4|@provedor'
Assert-Equal (Get-ShortName -Name $hkName) ($hkName.Split('|')[0]) 'ShortName remove separador final'
Assert-Equal (Get-ShortName -Name '[host.example] trojan-') 'host.example' 'ShortName so-protocolo cai no host'

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
Assert-True (Test-ConfigStable -Config @{ Protocol = 'vmess'; Network = 'ws'; Host = 'x.com' }) 'vmess+ws aceito'
Assert-True (-not (Test-ConfigStable -Config @{ Protocol = 'vmess'; Network = 'grpc'; Host = 'x.com' })) 'vmess+grpc rejeitado'

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

$vmessWs = @{ Protocol = 'vmess'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; AlterID = 0; Security = 'auto'; Network = 'ws'; TLS = 'tls'; SNI = 'cdn.example.com'; WsHost = 'cdn.example.com'; WsPath = '/p'; Params = ''; Name = 'v'; Ping = 50 }
Assert-True (Generate-V2RayConfig -Config $vmessWs -Tun $false) 'vmess+ws+tls gera (retorno true)'
$jsonWs = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonWs.outbounds[0].streamSettings.network 'ws' 'VMess ws network'
Assert-Equal $jsonWs.outbounds[0].streamSettings.wsSettings.path '/p' 'VMess ws path'
Assert-Equal $jsonWs.outbounds[0].streamSettings.wsSettings.headers.Host 'cdn.example.com' 'VMess ws Host'
Assert-Equal $jsonWs.outbounds[0].streamSettings.security 'tls' 'VMess ws tls'
Assert-Equal $jsonWs.outbounds[0].streamSettings.tlsSettings.serverName 'cdn.example.com' 'VMess ws SNI'

$vmessTcp = @{ Protocol = 'vmess'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; AlterID = 0; Security = 'auto'; Network = 'tcp'; Params = ''; Name = 'v'; Ping = 50 }
Assert-True (Generate-V2RayConfig -Config $vmessTcp -Tun $false) 'vmess+tcp gera (retorno true)'
$jsonVm = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonVm.outbounds[0].protocol 'vmess' 'VMess protocol'
Assert-Equal $jsonVm.outbounds[0].streamSettings.network 'tcp' 'VMess network tcp'

# Parse-VmessConfig nao produz a chave Params: o gerador nao pode exigir ela
$vmessNoParams = @{ Protocol = 'vmess'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; AlterID = 0; Security = 'auto'; Network = 'tcp'; Name = 'v'; Ping = 50 }
Assert-True (Generate-V2RayConfig -Config $vmessNoParams -Tun $false) 'vmess sem chave Params gera (retorno true)'

Write-Host "`n== Geracao de config com portas customizadas (scan paralelo) ==" -ForegroundColor Cyan

$scanCfgPath = Join-Path $Script:TempDir 'config-scan-custom.json'
Assert-True (Generate-V2RayConfig -Config $vlessCfg -Tun $false -SocksPort 10818 -HttpPort 10819 -ConfigPath $scanCfgPath) 'Gera config com porta custom (retorno true)'
$jsonScan = Get-Content $scanCfgPath -Raw | ConvertFrom-Json
$socksIn = @($jsonScan.inbounds | Where-Object { $_.protocol -eq 'socks' })[0]
$httpIn = @($jsonScan.inbounds | Where-Object { $_.protocol -eq 'http' })[0]
Assert-Equal $socksIn.port 10818 'Config scan: socks na porta custom'
Assert-Equal $httpIn.port 10819 'Config scan: http na porta custom'
Assert-True (Test-Path $scanCfgPath) 'Config scan: arquivo gravado no caminho custom'

Write-Host "`n== Seguranca do config: listen local + VLESS flow/packetEncoding ==" -ForegroundColor Cyan

Assert-True (@($jsonScan.inbounds | Where-Object { $_.listen -ne '127.0.0.1' }).Count -eq 0) 'Inbounds escutam apenas em 127.0.0.1'

$vlFlow = @{ Protocol = 'vless'; Host = '1.2.3.4'; Port = 443; UUID = '123e4567-e89b-12d3-a456-426614174000'; Params = 'flow=xtls-rprx-vision&packetEncoding=xudp&encryption=none'; Name = 'f'; Ping = 10 }
Assert-True (Generate-V2RayConfig -Config $vlFlow -Tun $false) 'VLESS flow gera (retorno true)'
$jsonFlow = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonFlow.outbounds[0].settings.vnext[0].users[0].flow 'xtls-rprx-vision' 'VLESS flow no user'
Assert-Equal $jsonFlow.outbounds[0].settings.packetEncoding 'xudp' 'VLESS packetEncoding'
Assert-Equal $jsonFlow.log.loglevel 'warning' 'loglevel warning (evita log gigante)'

Write-Host "`n== Get-XrayLogTail (resumo de erro, sem falso-positivo) ==" -ForegroundColor Cyan

$fakeLog = @(
    '2026/08/19 10:26:00.1 [Info] [1] proxy/socks: TCP Connect request to tcp:example.com:443',
    '2026/08/19 10:26:00.2 [Info] [1] proxy/vless/outbound: tunneling request to tcp:example.com:443 via 104.16.174.46:443',
    '2026/08/19 10:26:01.3 [Info] [1] transport/internet: failed to dial to (ws://104.16.104.151/): 409 Conflict > websocket: bad handshake',
    '2026/08/19 10:26:02.4 [Info] [1] proxy/trojan: connection ends > websocket: close 1006 (abnormal closure): unexpected EOF',
    '2026/08/19 10:26:03.5 [Info] [1] app/proxyman: failed to process outbound traffic > read tcp: forcibly closed'
)
Set-Content -Path $Script:XrayLog -Value $fakeLog -Encoding UTF8
$tail = Get-XrayLogTail -Lines 40
Assert-True ($tail -match '409 Conflict') 'LogTail captura 409 Conflict'
Assert-True ($tail -match 'bad handshake') 'LogTail captura bad handshake'
Assert-True ($tail -match 'unexpected EOF') 'LogTail captura unexpected EOF'
Assert-True ($tail -match 'forcibly closed') 'LogTail captura forcibly closed'
Assert-True (-not ($tail -match '443 via')) 'LogTail NAO produz falso-positivo (443 via)'
Assert-True (-not ($tail -match 'tunneling request')) 'LogTail NAO inclui linha de log crua'
Assert-True ($tail -notmatch "`n") 'LogTail retorna uma linha unica (sem quebra de linha)'

Set-Content -Path $Script:XrayLog -Value '2026/08/19 10:27:00.0 [Error] failed to create TUN interface: code 5'
Assert-True ((Get-XrayLogTail -Lines 40) -match 'TUN interface') 'LogTail fallback captura erro generico (TUN)'

Write-Host "`n== Format-Bytes ==" -ForegroundColor Cyan

Assert-Equal (Format-Bytes 0) '0 B' 'Format-Bytes 0'
Assert-Equal (Format-Bytes 1023) '1023 B' 'Format-Bytes 1023 B'
Assert-Equal (Format-Bytes 1024) '1.0 KB' 'Format-Bytes 1 KB'
Assert-Equal (Format-Bytes 1572864) '1.5 MB' 'Format-Bytes 1.5 MB'
Assert-Equal (Format-Bytes 3221225472) '3.0 GB' 'Format-Bytes 3 GB'

Write-Host "`n== Split tunneling: regras de rota ==" -ForegroundColor Cyan

$splitRules = @(New-SplitRoutingRules -Lines @('netflix.com', '1.2.3.4', '192.168.50.0/24', 'geoip:cn', '# ignorar', '') -NoLocal)
Assert-Equal $splitRules.Count 2 'Split: regras de dominio e de IP separadas (AND no Xray)'
$domRule = @($splitRules | Where-Object { $_.ContainsKey('domain') })[0]
$ipRule = @($splitRules | Where-Object { $_.ContainsKey('ip') })[0]
Assert-Equal (@($domRule.domain) -join ',') 'netflix.com' 'Split: dominio na regra de dominio'
Assert-True (@($ipRule.ip) -contains '1.2.3.4') 'Split: IP cru vai para a lista ip'
Assert-True (@($ipRule.ip) -contains '192.168.50.0/24') 'Split: CIDR vai para a lista ip'
Assert-True (@($ipRule.ip) -contains 'geoip:cn') 'Split: geoip: vai para a lista ip'
Assert-True (-not (@($domRule.domain) -contains 'geoip:cn')) 'Split: geoip: nao vira dominio'

$localRules = @(New-SplitRoutingRules -Lines @() )
Assert-Equal $localRules.Count 1 'Split sem regras: so a regra das faixas locais'
Assert-True (@($localRules[0].ip) -contains '10.0.0.0/8') 'Split: 10/8 direto'
Assert-True (@($localRules[0].ip) -contains 'fc00::/7') 'Split: fc00::/7 direto'
Assert-True (@($localRules[0].ip) -contains '192.168.0.0/16') 'Split: 192.168/16 direto'

$Script:SplitFile = Join-Path $Script:TempDir 'split-test.txt'
Set-Content -Path $Script:SplitFile -Value @('# comentario', 'netflix.com', '10.9.0.0/16') -Encoding UTF8
$splitLines = @(Get-SplitDirectLines)
Assert-Equal $splitLines.Count 2 'Split: Get-SplitDirectLines ignora comentario e vazio'

Assert-True (Generate-V2RayConfig -Config $vlessCfg -Tun $true) 'Split: gera config TUN com lista'
$jsonSplit = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonSplit.outbounds[0].protocol 'vless' 'Split: proxy continua o primeiro outbound'
Assert-Equal $jsonSplit.outbounds[1].tag 'direct' 'Split: outbound direct adicionado'
$splitDomainRule = @($jsonSplit.routing.rules | Where-Object { $_.PSObject.Properties['domain'] -and ($_.domain -contains 'netflix.com') })[0]
Assert-True ($null -ne $splitDomainRule) 'Split: regra de dominio no config'
Assert-Equal $splitDomainRule.outboundTag 'direct' 'Split: dominio vai para direct'

Write-Host "`n== API de estatisticas no config ==" -ForegroundColor Cyan

Assert-True (Generate-V2RayConfig -Config $vlessCfg -ApiPort 10099) 'Stats: gera config com API'
$jsonStats = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-Equal $jsonStats.api.tag 'api' 'Stats: api.tag=api'
Assert-True ($jsonStats.PSObject.Properties.Name -contains 'stats') 'Stats: secao stats presente'
Assert-Equal $jsonStats.policy.system.statsInboundDownlink $true 'Stats: policy downlink'
$apiIn = @($jsonStats.inbounds | Where-Object { $_.PSObject.Properties['tag'] -and $_.tag -eq 'api' })[0]
Assert-Equal $apiIn.protocol 'dokodemo-door' 'Stats: inbound api e dokodemo-door'
Assert-Equal $apiIn.port 10099 'Stats: porta do inbound api'
Assert-True (@($jsonStats.routing.rules | Where-Object { $_.PSObject.Properties['inboundTag'] -and ($_.inboundTag -contains 'api') }).Count -eq 1) 'Stats: routing api->api presente'

Assert-True (Generate-V2RayConfig -Config $vlessCfg -ApiPort 0) 'Stats: ApiPort 0 desabilita'
$jsonNoApi = Get-Content $Script:ConfigJson -Raw | ConvertFrom-Json
Assert-True (-not ($jsonNoApi.PSObject.Properties.Name -contains 'api')) 'Stats: sem api quando ApiPort 0'
Assert-True (@($jsonNoApi.inbounds | Where-Object { $_.PSObject.Properties['tag'] -and $_.tag -eq 'api' }).Count -eq 0) 'Stats: sem inbound api quando ApiPort 0'

Write-Host "`n== GeoIP offline (busca binaria) ==" -ForegroundColor Cyan

$geoPath = Join-Path $Script:TempDir 'geoip-test.bin'
$geoStream = [System.IO.File]::Create($geoPath)
$geoWriter = New-Object System.IO.BinaryWriter($geoStream)
function Add-GeoRecord {
    param($Writer, [string]$Start, [string]$End, [string]$Cc)
    foreach ($ip in @($Start, $End)) {
        $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
        $Writer.Write([System.BitConverter]::ToUInt32([byte[]]@($b[3], $b[2], $b[1], $b[0]), 0))
    }
    $Writer.Write([System.Text.Encoding]::ASCII.GetBytes($Cc))
}
Add-GeoRecord $geoWriter '1.0.0.0' '1.0.0.255' 'AU'
Add-GeoRecord $geoWriter '8.8.8.0' '8.8.8.255' 'US'
Add-GeoRecord $geoWriter '200.0.0.0' '200.255.255.255' 'BR'
Add-GeoRecord $geoWriter '203.0.113.0' '203.0.113.255' 'ZZ'
$geoWriter.Flush(); $geoWriter.Dispose(); $geoStream.Dispose()

$Script:GeoIpFile = $geoPath
$Script:GeoIpData = $null
Assert-Equal (Get-CountryCodeOffline -Ip '1.0.0.1') 'AU' 'GeoIP: dentro do primeiro registro'
# Regressao: se os bytes voltarem pelo pipeline, o PowerShell desenrola 3.6M
# objetos e cada consulta leva minutos (BitConverter reconvertendo object[]).
Assert-True ($Script:GeoIpData -is [byte[]]) 'GeoIP: cache guarda byte[] (sem unroll do pipeline)'
Assert-Equal (Get-CountryCodeOffline -Ip '8.8.8.8') 'US' 'GeoIP: 8.8.8.8 (meio da base)'
Assert-Equal (Get-CountryCodeOffline -Ip '200.160.0.1') 'BR' 'GeoIP: faixa grande'
Assert-Equal (Get-CountryCodeOffline -Ip '200.255.255.255') 'BR' 'GeoIP: limite superior'
Assert-Equal (Get-CountryCodeOffline -Ip '9.9.9.9') '' 'GeoIP: fora da base -> vazio'
Assert-Equal (Get-CountryCodeOffline -Ip '203.0.113.5') '' 'GeoIP: ZZ (desconhecido) -> vazio'
Assert-Equal (Get-CountryCodeOffline -Ip '2001:4860:4860::8888') '' 'GeoIP: IPv6 ignorado'
Assert-Equal (Get-CountryCodeOffline -Ip 'nao-e-ip') '' 'GeoIP: entrada invalida'
$Script:GeoIpFile = Join-Path $Script:TempDir 'nao-existe.bin'
$Script:GeoIpData = $null
Assert-Equal (Get-CountryCodeOffline -Ip '1.0.0.1') '' 'GeoIP: sem arquivo -> vazio (sem excecao)'

Write-Host "`n== GUI: XAML dos dialogos ==" -ForegroundColor Cyan

# Regressao: x:Name sem xmlns:x fazia o editor de split falhar com
# "The 'x' prefix is not bound" ao carregar o XAML.
$guiSrc = [System.IO.File]::ReadAllText((Join-Path $root 'Core\SettVPN_Gui.ps1'))
$guiXamls = @(
    @{ Name = 'janela principal'; Pattern = '\[xml\]\$xaml = @"(?<x>[\s\S]*?)"@' },
    @{ Name = 'split tunneling'; Pattern = '\$xaml = @''(?<x>[\s\S]*?)''@' },
    @{ Name = 'configuracoes'; Pattern = '\[xml\]\$settingsXaml = @''(?<x>[\s\S]*?)''@' }
)
foreach ($case in $guiXamls) {
    $m = [regex]::Match($guiSrc, $case.Pattern)
    $ok = $false
    if ($m.Success) {
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.LoadXml($m.Groups['x'].Value)
            $ok = ($doc.DocumentElement.GetAttribute('xmlns:x') -eq 'http://schemas.microsoft.com/winfx/2006/xaml')
        }
        catch { $ok = $false }
    }
    Assert-True $ok "GUI: XAML de $($case.Name) declara xmlns:x e parseia"
}
Assert-True ($guiSrc -match '\$Script:GuiBtnProxy\s+= \$Script:GuiSettings\.FindName') 'GUI: toggles vem da janela de configuracoes'
Assert-True ($guiSrc -match 'x:Name="cbCountry"' -and $guiSrc -match 'ComboBox') 'GUI: filtro por pais existe'
Assert-True ($guiSrc -match 'x:Name="btnSort"' -and $guiSrc -match 'SortDesc') 'GUI: ordenacao por ping existe'
Assert-True ($guiSrc -notmatch 'x:Name="btnFilter"') 'GUI: sem botao TESTAR (ATUALIZAR ja testa)'
Assert-True ($guiSrc -match 'function Sync-SystemProxy' -and $guiSrc -match '(?m)^\s+Sync-SystemProxy\s*$') 'GUI: proxy do sistema liga sozinho ao conectar'

Write-Host "`n== Kill switch: script elevado ==" -ForegroundColor Cyan

# O script elevado e montado a partir de uma variavel de script (nao extraida pelo AST
# dos testes): pega o valor real da atribuicao no arquivo.
$ksAssign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Script:KillSwitchFuncs' }, $true)
Assert-True ($null -ne $ksAssign) 'Kill switch: atribuicao de KillSwitchFuncs encontrada'
$Script:KillSwitchFuncs = & ([scriptblock]::Create($ksAssign.Right.Extent.Text))

$ksParsed = $true
try { [void][scriptblock]::Create($Script:KillSwitchFuncs) } catch { $ksParsed = $false }
Assert-True $ksParsed 'Kill switch: funcoes de firewall parseiam'
Assert-True ($Script:KillSwitchFuncs -match 'Restore-SettVpnFirewall') 'Kill switch: restaurador presente'
Assert-True ($Script:KillSwitchFuncs -match 'Enable-SettVpnKillSwitch') 'Kill switch: ativador presente'
Assert-True ($Script:KillSwitchFuncs -match 'DefaultOutboundAction') 'Kill switch: bloqueia saida padrao'
Assert-True ($Script:KillSwitchFuncs -match 'InterfaceDescription -match ''Wintun''') 'Kill switch: libera a interface TUN'
Assert-True ($Script:KillSwitchFuncs -match 'Remove-NetFirewallRule -Group ''SettVPN KillSwitch''') 'Kill switch: limpa as regras do grupo'
Assert-True ($Script:KillSwitchFuncs -match 'WriteAllText\(\$backup') 'Kill switch: backup em disco antes de bloquear'

$Script:AppLog = Join-Path $Script:TempDir 'app-test.log'
$supervisor = New-SupervisorScript
$supParsed = $true
try { [void][scriptblock]::Create($supervisor) } catch { $supParsed = $false }
Assert-True $supParsed 'Supervisor: script completo parseia (roda elevado via -EncodedCommand)'
Assert-True ($supervisor -match 'SETTVPN_READY') 'Supervisor: espera o app confirmar o tunel'
Assert-True ($supervisor -match 'SETTVPN_KS_BACKUP') 'Supervisor: restaura o firewall ao sair'
Assert-True ($supervisor -match 'gstatic.com/generate_204') 'Supervisor: valida conectividade (fail-open)'
Assert-True ($supervisor -match 'Restore-SettVpnFirewall') 'Supervisor: restaura firewall no finally'
Assert-True ($null -ne (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) 'Kill switch: New-NetFirewallRule disponivel'
Assert-True ($null -ne (Get-Command Set-NetFirewallProfile -ErrorAction SilentlyContinue)) 'Kill switch: Set-NetFirewallProfile disponivel'

Write-Host ''
Write-Host "Resultado: $($script:Pass) passaram, $($script:Fail) falharam"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
