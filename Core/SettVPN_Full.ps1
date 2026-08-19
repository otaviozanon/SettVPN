# SettVPN - Automated VPN Connection Manager
# Uses abc-configs free VPN servers with embedded v2ray-core

param([switch]$Console)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================
# GLOBAL VARIABLES
# ============================================================

$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ScriptFile = $MyInvocation.MyCommand.Path
$Script:TempDir = Join-Path $env:TEMP "SettVPN"
$Script:V2RayExe = Join-Path $Script:TempDir "v2ray.exe"
$Script:WintunDll = Join-Path $Script:TempDir "wintun.dll"
$Script:ConfigJson = Join-Path $Script:TempDir "config.json"
$Script:XrayLog = Join-Path $Script:TempDir "xray.log"
$Script:ReadmeCache = Join-Path $Script:TempDir "abc-configs-README.md"
$Script:SubCache = Join-Path $Script:TempDir "pawdroid-sub.txt"
$Script:Sub2Cache = Join-Path $Script:TempDir "peasoft-sub.txt"
$Script:V2RayProcess = $null
$Script:CurrentConfig = $null
$Script:AbcConfigsUrl = "https://raw.githubusercontent.com/FreeFolksOn/abc-configs-free-vpn-proxy-list/main/README.md"
$Script:SubConfigsUrl = "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"
$Script:Sub2ConfigsUrl = "https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list.txt"

# ============================================================
# V2RAY - extraido pelo launcher (SettVPN.exe) para %TEMP%\SettVPN\v2ray.exe
# V2RayBase64 mantido apenas como fallback para execucao direta do script
# ============================================================

$Script:V2RayBase64 = $null

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Status {
    param([string]$Message, [string]$Type = "INFO")
    
    $prefix = switch ($Type) {
        "OK"    { "[+]" }
        "ERROR" { "[!]" }
        "WARN"  { "[*]" }
        "INFO"  { "[i]" }
        default { "[i]" }
    }
    
    $color = switch ($Type) {
        "OK"    { "Green" }
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "INFO"  { "Cyan" }
        default { "White" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Initialize-Environment {
    if (-not (Test-Path $Script:TempDir)) {
        New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
        Write-Status "Created temp directory: $Script:TempDir" "OK"
    }
}

function Extract-V2Ray {
    if (Test-Path $Script:V2RayExe) {
        Write-Status "v2ray.exe already extracted" "INFO"
        return $true
    }
    
    if ([string]::IsNullOrEmpty($Script:V2RayBase64)) {
        Write-Status "v2ray.exe not found and no embedded fallback. Run via SettVPN.exe." "ERROR"
        return $false
    }

    try {
        Write-Status "Extracting v2ray.exe from embedded data..." "INFO"
        $bytes = [Convert]::FromBase64String($Script:V2RayBase64)
        [System.IO.File]::WriteAllBytes($Script:V2RayExe, $bytes)
        Write-Status "v2ray.exe extracted successfully" "OK"
        return $true
    }
    catch {
        Write-Status "Failed to extract v2ray.exe: $_" "ERROR"
        return $false
    }
}

# ============================================================
# CONFIG PARSER FUNCTIONS
# ============================================================

function Parse-VlessConfig {
    param([string]$Uri)
    
    try {
        if ($Uri -match '^vless://([^@]+)@([^:]+):(\d+)(?:\?(.*?))?(?:#(.*))?$') {
            $uuid = $matches[1]
            $srvHost = $matches[2]
            $port = [int]$matches[3]
            $params = ""
            $name = $srvHost
            if ($matches[4]) { $params = $matches[4] }
            if ($matches[5]) { $name = Unescape-Safe $matches[5] }

            $guid = [guid]::Empty
            if (-not [guid]::TryParse($uuid, [ref]$guid)) {
                Write-Status "Skipping VLESS config with non-UUID id: $uuid" "WARN"
                return $null
            }
            
            return @{
                Protocol = "vless"
                UUID = $uuid
                Host = $srvHost
                Port = $port
                Params = $params
                Name = $name
                Raw = $Uri
            }
        }
    }
    catch {
        Write-Status "Failed to parse VLESS config: $_" "WARN"
    }
    
    return $null
}

function Parse-ShadowsocksConfig {
    param([string]$Uri)
    
    try {
        if ($Uri -match '^ss://([^@]+)@([^:]+):(\d+)(?:\?(.*?))?(?:#(.*))?$') {
            $encoded = $matches[1]
            $srvHost = $matches[2]
            $port = [int]$matches[3]
            $params = ""
            $name = $srvHost
            if ($matches[4]) { $params = $matches[4] }
            if ($matches[5]) { $name = Unescape-Safe $matches[5] }
            
            # Try to decode base64
            try {
                $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
                if ($decoded -match '^([^:]+):(.+)$') {
                    $method = $matches[1]
                    $password = $matches[2]
                }
                else {
                    $method = "unknown"
                    $password = $encoded
                }
            }
            catch {
                $method = "unknown"
                $password = $encoded
            }
            
            return @{
                Protocol = "shadowsocks"
                Method = $method
                Password = $password
                Host = $srvHost
                Port = $port
                Params = $params
                Name = $name
                Raw = $Uri
            }
        }
    }
    catch {
        Write-Status "Failed to parse Shadowsocks config: $_" "WARN"
    }

    return $null
}

function Parse-TrojanConfig {
    param([string]$Uri)

    try {
        if ($Uri -match '^trojan://([^@]+)@([^:]+):(\d+)(?:\?(.*?))?(?:#(.*))?$') {
            $password = $matches[1]
            $srvHost = $matches[2]
            $port = [int]$matches[3]
            $params = ""
            $name = $srvHost
            if ($matches[4]) { $params = $matches[4] }
            if ($matches[5]) { $name = Unescape-Safe $matches[5] }

            return @{
                Protocol = "trojan"
                Password = $password
                Host = $srvHost
                Port = $port
                Params = $params
                Name = $name
                Raw = $Uri
            }
        }
    }
    catch {
        Write-Status "Failed to parse Trojan config: $_" "WARN"
    }

    return $null
}

function Parse-VmessConfig {
    param([string]$Uri)

    try {
        # Format: vmess://base64encodedJSON
        if ($Uri -match 'vmess://(.+)') {
            $base64 = $matches[1]
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))
            $json = $decoded | ConvertFrom-Json

            return @{
                Protocol = "vmess"
                Host = $json.add
                Port = [int]$json.port
                UUID = $json.id
                AlterID = $json.aid
                Network = $json.net
                Type = $json.type
                Security = $json.scy
                Name = $json.ps
                Raw = $Uri
            }
        }
    }
    catch {
        Write-Status "Failed to parse VMess config: $_" "WARN"
    }

    return $null
}

function Download-AbcConfigs {
    # Check cache first - if less than 10 minutes old, use it
    if (Test-Path $Script:ReadmeCache) {
        $cacheAge = (Get-Date) - (Get-Item $Script:ReadmeCache).LastWriteTime
        if ($cacheAge.TotalMinutes -lt 10) {
            Write-Status "Using cached configs (updated $([math]::Round($cacheAge.TotalMinutes, 1)) min ago)" "INFO"
            return Get-Content $Script:ReadmeCache -Raw
        }
    }

    try {
        Write-Status "Downloading latest configs from GitHub..." "INFO"

        # Use Invoke-WebRequest with timeout
        $response = Invoke-WebRequest -Uri $Script:AbcConfigsUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $content = $response.Content

        # Cache locally
        Set-Content -Path $Script:ReadmeCache -Value $content -Encoding UTF8
        Write-Status "Downloaded and cached latest configs" "OK"
        return $content
    }
    catch {
        Write-Status "Failed to download from GitHub: $_" "WARN"

        # Try to use cached version (even if old)
        if (Test-Path $Script:ReadmeCache) {
            $cacheAge = (Get-Date) - (Get-Item $Script:ReadmeCache).LastWriteTime
            Write-Status "Using cached configs (updated $([math]::Round($cacheAge.TotalHours, 1)) hours ago)" "WARN"
            return Get-Content $Script:ReadmeCache -Raw
        }
        else {
            Write-Status "No cached configs available - cannot proceed" "ERROR"
            return $null
        }
    }
}

function ConvertTo-Config {
    param([string]$Uri)

    $parsed = $null
    if ($Uri -match '^vless://') {
        $parsed = Parse-VlessConfig -Uri $Uri
    }
    elseif ($Uri -match '^vmess://') {
        $parsed = Parse-VmessConfig -Uri $Uri
    }
    elseif ($Uri -match '^trojan://') {
        $parsed = Parse-TrojanConfig -Uri $Uri
    }
    elseif ($Uri -match '^ss://') {
        $parsed = Parse-ShadowsocksConfig -Uri $Uri
    }
    return $parsed
}

function Get-ShortName {
    param([string]$Name, [int]$Max = 26)

    # Encurta nomes de servidor (listas livres usam nomes muito longos) pra log nao cortar.
    if (-not $Name) { return "" }
    if ($Name.Length -le $Max) { return $Name }
    return $Name.Substring(0, [Math]::Max(1, $Max - 3)).TrimEnd() + "..."
}

function Download-SubSource {
    param([string]$Url, [string]$Cache, [string]$Label)

    if (Test-Path $Cache) {
        $cacheAge = (Get-Date) - (Get-Item $Cache).LastWriteTime
        if ($cacheAge.TotalMinutes -lt 10) {
            Write-Status "Using cached $($Label) (updated $([math]::Round($cacheAge.TotalMinutes, 1)) min ago)" "INFO"
            return Get-Content $Cache -Raw
        }
    }

    try {
        Write-Status "Downloading $($Label)..." "INFO"
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $encoded = $response.Content

        Set-Content -Path $Cache -Value $encoded -Encoding UTF8
        Write-Status "Downloaded and cached $($Label)" "OK"
        return $encoded
    }
    catch {
        Write-Status "Failed to download $($Label): $_" "WARN"

        if (Test-Path $Cache) {
            Write-Status "Using cached $($Label)" "WARN"
            return Get-Content $Cache -Raw
        }
        return $null
    }
}

function Get-AllConfigs {
    $configs = @()

    # Source 1: abc-configs (HTML README with <code> tags)
    $content = Download-AbcConfigs
    if ($content) {
        $pattern = '<code>(vless://[^<]+|vmess://[^<]+|trojan://[^<]+|ss://[^<]+)</code>'
        $matches = [regex]::Matches($content, $pattern)

        foreach ($match in $matches) {
            $uri = $match.Groups[1].Value -replace '&amp;', '&'
            $parsed = ConvertTo-Config -Uri $uri
            if ($parsed -and (Test-ConfigStable $parsed)) { $configs += $parsed }
        }
        Write-Status "abc-configs: $($matches.Count) found" "INFO"
    }

    # Sources 2-3: base64 subscription lists
    $subSources = @(
        @{ Url = $Script:SubConfigsUrl;  Cache = $Script:SubCache;  Label = "Pawdroid" },
        @{ Url = $Script:Sub2ConfigsUrl; Cache = $Script:Sub2Cache; Label = "peasoft" }
    )

    foreach ($src in $subSources) {
        $encoded = Download-SubSource -Url $src.Url -Cache $src.Cache -Label $src.Label
        if (-not $encoded) { continue }

        $rawLinks = ""
        try {
            $rawLinks = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Trim()))
        }
        catch {
            $rawLinks = $encoded
        }

        $count = 0
        foreach ($line in $rawLinks -split "[\r\n]+") {
            $line = $line.Trim()
            if ($line -match '^(vless|vmess|trojan|ss)://') {
                $count++
                $parsed = ConvertTo-Config -Uri $line
                if ($parsed -and (Test-ConfigStable $parsed)) { $configs += $parsed }
            }
        }
        Write-Status "$($src.Label): $count found" "INFO"
    }

    # Dedup: remove espelhos (mesmo protocolo+host+porta vindos de agregadores diferentes)
    $seen = @{}
    $unique = @()
    foreach ($cfg in $configs) {
        $key = "$($cfg.Protocol)|$($cfg.Host)|$($cfg.Port)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $cfg
        }
    }
    $dupes = $configs.Count - $unique.Count
    if ($dupes -gt 0) { Write-Status "Removidos $dupes duplicados (espelhos)" "INFO" }
    $configs = $unique

    if ($configs.Count -gt 400) {
        $configs = @($configs[0..399])
    }
    Write-Status "Found $($configs.Count) configs (apos filtro)" "INFO"
    return $configs
}

# ============================================================
# PING CHECKER FUNCTIONS
# ============================================================

function Get-ConfigsWithPing {
    param([array]$Configs)

    $n = $Configs.Count
    Write-Status "Testing connectivity for $n configs..." "INFO"

    $timeoutMs = 3000

    $tcpArr = [object[]]::new($n)
    $swArr  = [object[]]::new($n)
    $arArr  = [object[]]::new($n)
    $done   = [bool[]]::new($n)

    # fire all TCP connects at once (non-blocking)
    for ($i = 0; $i -lt $n; $i++) {
        $cfg = $Configs[$i]
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($cfg.Host, $cfg.Port, $null, $null)
            $tcpArr[$i] = $tcp
            $swArr[$i] = $sw
            $arArr[$i] = $ar
        }
        catch {
            $sw.Stop()
            $cfg.Ping = 9999
            $done[$i] = $true
            $tcp.Close()
        }
    }

    # collect results as they complete (poll every 20ms, shared deadline)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    $remaining = $n
    while ($remaining -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        for ($i = 0; $i -lt $n; $i++) {
            if ($done[$i] -or $null -eq $arArr[$i]) { continue }
            if ($arArr[$i].IsCompleted) {
                $cfg = $Configs[$i]
                try {
                    $tcpArr[$i].EndConnect($arArr[$i])
                    $swArr[$i].Stop()
                    $cfg.Ping = [int]$swArr[$i].ElapsedMilliseconds
                }
                catch {
                    $swArr[$i].Stop()
                    $cfg.Ping = 9999
                }
                finally {
                    $tcpArr[$i].Close()
                }
                $done[$i] = $true
                $remaining--
            }
        }
        if ($remaining -gt 0) { Start-Sleep -Milliseconds 20 }
    }

    # anything still not done -> unreachable
    for ($i = 0; $i -lt $n; $i++) {
        if (-not $done[$i]) {
            $Configs[$i].Ping = 9999
            if ($null -ne $tcpArr[$i]) { try { $tcpArr[$i].Close() } catch {} }
        }
    }

    # Sort by ping (lowest first), exclude unreachable (9999ms)
    $filtered = $Configs | Where-Object { $_.Ping -lt 9999 }

    if ($filtered) {
        $sorted = @($filtered) | Sort-Object -Property @{ Expression = { [int]$_.Ping } }
    }
    else {
        $sorted = @()
    }

    Write-Status "Found $($sorted.Count) reachable servers" "OK"
    return $sorted
}

# ============================================================
# V2RAY CONFIG GENERATOR
# ============================================================

function Unescape-Safe {
    param([string]$Value)
    try { return [Uri]::UnescapeDataString($Value) }
    catch { return $Value }
}

function ConvertTo-ParamHashtable {
    param([string]$Params)

    $result = @{}
    if (-not [string]::IsNullOrEmpty($Params)) {
        foreach ($pair in $Params -split '&') {
            if ($pair -match '^([^=]+)=(.+)$') {
                $key = $matches[1]
                $value = Unescape-Safe $matches[2]
                $result[$key] = $value
            }
        }
    }
    return $result
}

function Get-ParamValue {
    param([hashtable]$P, [string]$Key, [string]$Default = "")
    if ($P.ContainsKey($Key)) { return $P[$Key] }
    return $Default
}

function New-StreamSettings {
    param([hashtable]$P)

    $network  = Get-ParamValue $P "type" "tcp"
    $security = Get-ParamValue $P "security" "none"

    $stream = @{
        network  = $network
        security = $security
    }

    if ($security -eq "tls") {
        $tls = @{}
        $sni = Get-ParamValue $P "sni"
        if ($sni) { $tls.serverName = $sni }
        $alpn = Get-ParamValue $P "alpn"
        if ($alpn) { $tls.alpn = @($alpn -split ',') }
        $fp = Get-ParamValue $P "fp"
        if ($fp) { $tls.fingerprint = $fp }
        $stream.tlsSettings = $tls
    }
    elseif ($security -eq "reality") {
        $r = @{}
        $sni = Get-ParamValue $P "sni"
        if ($sni) { $r.serverName = $sni }
        $fp = Get-ParamValue $P "fp"
        if ($fp) { $r.fingerprint = $fp }
        $pbk = Get-ParamValue $P "pbk"
        if ($pbk) { $r.publicKey = $pbk }
        $sid = Get-ParamValue $P "sid"
        if ($sid) { $r.shortId = $sid }
        $spx = Get-ParamValue $P "spx"
        if ($spx) { $r.spiderX = $spx }
        $stream.realitySettings = $r
    }

    if ($network -eq "ws") {
        $ws = @{}
        $path = Get-ParamValue $P "path"
        if ($path) { $ws.path = $path }
        $hdr = Get-ParamValue $P "host"
        if ($hdr) { $ws.headers = @{ Host = $hdr } }
        $stream.wsSettings = $ws
    }
    elseif ($network -eq "grpc") {
        $g = @{}
        $svc = Get-ParamValue $P "serviceName"
        if ($svc) { $g.serviceName = $svc }
        $stream.grpcSettings = $g
    }
    elseif ($network -eq "xhttp") {
        $x = @{}
        $path = Get-ParamValue $P "path"
        if ($path) { $x.path = $path }
        $hdr = Get-ParamValue $P "host"
        if ($hdr) { $x.host = $hdr }
        $mode = Get-ParamValue $P "mode"
        if ($mode) { $x.mode = $mode }
        $stream.xhttpSettings = $x
    }

    return $stream
}

function Generate-V2RayConfig {
    param([hashtable]$Config, [bool]$Tun = $false)

    $configObj = @{
        log = @{
            loglevel = "info"
            error    = $Script:XrayLog
        }
        inbounds = @(
            @{
                port = 10808
                protocol = "socks"
                settings = @{
                    auth = "noauth"
                    udp = $true
                }
            },
            @{
                port = 10809
                protocol = "http"
                settings = @{}
            }
        )
        outbounds = @()
    }

    if ($Tun) {
        $configObj.inbounds += @{
            tag      = "tun-in"
            protocol = "tun"
            settings = @{
                mtu                    = 1500
                gateway                = @("10.0.0.1/16", "fc00::1/64")
                dns                    = @("1.1.1.1", "8.8.8.8")
                autoSystemRoutingTable = @("0.0.0.0/0", "::/0")
                autoOutboundsInterface = "auto"
            }
        }
    }

    $paramHash = ConvertTo-ParamHashtable -Params $Config.Params

    if ((Get-ParamValue $paramHash "type" "tcp") -eq "xhttp") {
        Write-Status "Skipping config (transport xhttp not supported by this v2ray build)" "WARN"
        return $false
    }

    if ($Config.Protocol -eq "vless") {
        $stream = New-StreamSettings -P $paramHash
        $outbound = @{
            protocol = "vless"
            settings = @{
                vnext = @(
                    @{
                        address = $Config.Host
                        port = $Config.Port
                        users = @(
                            @{
                                id = $Config.UUID
                                encryption = "none"
                            }
                        )
                    }
                )
            }
            streamSettings = $stream
        }
        $configObj.outbounds += $outbound
    }
    elseif ($Config.Protocol -eq "shadowsocks") {
        $network = Get-ParamValue $paramHash "type" "tcp"
        if ($Config.Method -eq "unknown" -or $network -ne "tcp") {
            Write-Status "Skipping unsupported Shadowsocks config (method: $($Config.Method), transport: $network)" "WARN"
            return $false
        }
        $outbound = @{
            protocol = "shadowsocks"
            settings = @{
                servers = @(
                    @{
                        address = $Config.Host
                        port = $Config.Port
                        method = $Config.Method
                        password = $Config.Password
                    }
                )
            }
        }
        $configObj.outbounds += $outbound
    }
    elseif ($Config.Protocol -eq "trojan") {
        $stream = New-StreamSettings -P $paramHash
        if ($stream.security -eq "none") { $stream.security = "tls" }
        $outbound = @{
            protocol = "trojan"
            settings = @{
                servers = @(
                    @{
                        address = $Config.Host
                        port = $Config.Port
                        password = $Config.Password
                    }
                )
            }
            streamSettings = $stream
        }
        $configObj.outbounds += $outbound
    }
    elseif ($Config.Protocol -eq "vmess") {
        $outbound = @{
            protocol = "vmess"
            settings = @{
                vnext = @(
                    @{
                        address = $Config.Host
                        port = $Config.Port
                        users = @(
                            @{
                                id = $Config.UUID
                                alterId = $Config.AlterID
                                security = $Config.Security
                            }
                        )
                    }
                )
            }
            streamSettings = @{
                network = $Config.Network
            }
        }
        $configObj.outbounds += $outbound
    }

    # Save to file
    try {
        $json = $configObj | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($Script:ConfigJson, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Status "Generated v2ray config: $Script:ConfigJson" "OK"
        return $true
    }
    catch {
        Write-Status "Failed to generate config: $_" "ERROR"
        return $false
    }
}

# ============================================================
# V2RAY PROCESS MANAGER
# ============================================================

function Test-CloudflareIp {
    param([string]$IpString)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpString, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    $a = [int]$bytes[0]; $b = [int]$bytes[1]
    if ($a -eq 104 -and $b -ge 16 -and $b -le 31) { return $true }
    if ($a -eq 172 -and $b -ge 64 -and $b -le 71) { return $true }
    if ($a -eq 162 -and ($b -eq 158 -or $b -eq 159)) { return $true }
    if ($a -eq 173 -and $b -eq 245) { return $true }
    if ($a -eq 141 -and $b -eq 101) { return $true }
    if ($a -eq 188 -and $b -eq 114) { return $true }
    if ($a -eq 190 -and $b -eq 93) { return $true }
    if ($a -eq 197 -and $b -eq 234) { return $true }
    if ($a -eq 198 -and $b -eq 41) { return $true }
    return $false
}

function Test-ConfigStable {
    param([hashtable]$Config)

    # Rejeita apenas transports que o gerador de config nao suporta (xhttp) ou instaveis (grpc).
    # Reality e IPs Cloudflare agora passam: o teste de tunel (TLS real) decide se funcionam.
    $params = [string]$Config['Params']
    if ($params) {
        if ($params -match 'type=(grpc|xhttp)') { return $false }
    }

    return $true
}

function Scan-StableServers {
    param([array]$Configs, [int]$MaxToTest = 25, [int]$StabilitySeconds = 6, [int]$MinStable = 10)

    $stable = @()
    $tested = 0
    $total = [Math]::Min($Configs.Count, $MaxToTest)
    if ($total -le 0) { return $stable }
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Sync) {
        $Sync.ScanTotal = $total; $Sync.ScanTested = 0; $Sync.ScanStart = [DateTime]::Now
        $Sync.ScanDeadline = [DateTime]::Now.AddSeconds($total * 30)
    }
    foreach ($cfg in $Configs) {
        if ($tested -ge $MaxToTest) { break }
        $tested++
        if ($Sync) { $Sync.ScanTested = $tested; $Sync.Progress = [int](($tested / $total) * 100) }
        Write-Status "Testando estabilidade ($tested/$total): $(Get-ShortName $cfg.Name)" "INFO"
        if (Start-V2Ray -Config $cfg -StabilitySeconds $StabilitySeconds) {
            # Exige UDP alem de TCP (Discord/voz, jogos, DNS usam UDP)
            $udpOk = Test-V2RayUdp
            Stop-V2Ray
            if ($udpOk) {
                $stable += $cfg
                Write-Status "Estavel (TCP+UDP): $(Get-ShortName $cfg.Name)" "OK"
                if ($MinStable -gt 0 -and $stable.Count -ge $MinStable) {
                    Write-Status "Encerrando scan: $($stable.Count) servidores estaveis" "OK"
                    break
                }
            }
            else {
                Write-Status "Sem UDP (descartado): $(Get-ShortName $cfg.Name)" "WARN"
            }
        }
        else {
            Write-Status "Descartado: $(Get-ShortName $cfg.Name)" "WARN"
        }
        # ETA adaptativo: media real de tempo por servidor x servidores restantes
        if ($Sync) {
            $eta = Get-ScanEtaSeconds -ElapsedSeconds $scanSw.Elapsed.TotalSeconds -Total $total -Tested $tested
            $Sync.ScanDeadline = [DateTime]::Now.AddSeconds($eta)
        }
    }
    if ($Sync) { $Sync.Progress = 100; $Sync.ScanDeadline = [DateTime]::Now }
    return $stable
}

function Get-ScanEtaSeconds {
    param([double]$ElapsedSeconds, [int]$Total, [int]$Tested)

    # Tempo medio real por servidor (dos ja testados) x servidores restantes.
    if ($Total -le 0 -or $Tested -le 0) { return 0.0 }
    $avg = $ElapsedSeconds / $Tested
    $left = [Math]::Max(0, $Total - $Tested)
    return [double]($left * $avg)
}

function Get-ScanRemainingSeconds {
    param([datetime]$Deadline = [DateTime]::MinValue)

    # Contagem regressiva a partir do deadline estimado (cai 1s por segundo).
    if ($Deadline -eq [DateTime]::MinValue) { return 0 }
    return [int][Math]::Max(0, [Math]::Ceiling(($Deadline - [DateTime]::Now).TotalSeconds))
}

# ============================================================
# GEOLOCALIZACAO (pais do servidor)
# ============================================================

function Get-CountryNamePt {
    param([string]$Code)

    if (-not $Code) { return "" }
    $map = @{
        'US' = 'Estados Unidos'; 'BR' = 'Brasil'; 'FR' = 'Franca'; 'RU' = 'Russia';
        'DE' = 'Alemanha'; 'NL' = 'Holanda'; 'GB' = 'Reino Unido'; 'CA' = 'Canada';
        'JP' = 'Japao'; 'SG' = 'Singapura'; 'HK' = 'Hong Kong'; 'KR' = 'Coreia do Sul';
        'TR' = 'Turquia'; 'UA' = 'Ucrania'; 'PL' = 'Polonia'; 'SE' = 'Suecia';
        'IN' = 'India'; 'IT' = 'Italia'; 'ES' = 'Espanha'; 'CH' = 'Suica';
        'AR' = 'Argentina'; 'CO' = 'Colombia'; 'MX' = 'Mexico'; 'CL' = 'Chile';
        'PT' = 'Portugal'; 'AT' = 'Austria'; 'BE' = 'Belgica'; 'BG' = 'Bulgaria';
        'CZ' = 'Republica Tcheca'; 'DK' = 'Dinamarca'; 'FI' = 'Finlandia'; 'GR' = 'Grecia';
        'HU' = 'Hungria'; 'IE' = 'Irlanda'; 'IL' = 'Israel'; 'NO' = 'Noruega';
        'RO' = 'Romenia'; 'ZA' = 'Africa do Sul'; 'AU' = 'Australia'; 'NZ' = 'Nova Zelandia';
        'TW' = 'Taiwan'; 'VN' = 'Vietna'; 'TH' = 'Tailandia'; 'MY' = 'Malasia';
        'ID' = 'Indonesia'; 'PH' = 'Filipinas'; 'AE' = 'Emirados Arabes'; 'SA' = 'Arabia Saudita';
        'EG' = 'Egito'; 'NG' = 'Nigeria'; 'KE' = 'Quenia'; 'PK' = 'Paquistao';
        'BD' = 'Bangladesh'; 'IR' = 'Ira'; 'IQ' = 'Iraque'; 'KZ' = 'Cazaquistao';
        'GE' = 'Georgia'; 'AM' = 'Armenia'; 'AZ' = 'Azerbaijao'; 'BY' = 'Bielorrussia';
        'MD' = 'Moldavia'; 'RS' = 'Servia'; 'HR' = 'Croacia'; 'SI' = 'Eslovenia';
        'SK' = 'Eslovaquia'; 'LT' = 'Lituania'; 'LV' = 'Letonia'; 'EE' = 'Estonia';
        'CN' = 'China'; 'LU' = 'Luxemburgo'; 'IS' = 'Islandia'; 'CY' = 'Chipre';
        'MT' = 'Malta'; 'MC' = 'Monaco'; 'LI' = 'Liechtenstein'; 'AD' = 'Andorra';
        'DO' = 'Republica Dominicana'; 'UY' = 'Uruguai'; 'PY' = 'Paraguai'; 'PE' = 'Peru';
        'VE' = 'Venezuela'; 'EC' = 'Equador'; 'BO' = 'Bolivia'; 'GT' = 'Guatemala';
        'CR' = 'Costa Rica'; 'PA' = 'Panama'; 'CU' = 'Cuba'; 'PR' = 'Porto Rico';
    }
    if ($map.ContainsKey($Code)) { return $map[$Code] }
    return $Code
}

function Get-CountryCodeFromName {
    param([string]$Name)

    # Infere o codigo de pais a partir de um token de 2 letras MAIUSCULAS no nome
    # (ex: "US_speednode_0123" -> US). Soh aceita codigos presentes no mapa.
    if (-not $Name) { return "" }
    foreach ($m in [regex]::Matches($Name, '(?<![A-Za-z])([A-Z]{2})(?![A-Za-z])')) {
        $code = $m.Groups[1].Value
        $pt = Get-CountryNamePt -Code $code
        if ($pt -and $pt -ne $code) { return $code }
    }
    return ""
}

function Resolve-Countries {
    param([array]$Configs)

    if (-not $Configs -or $Configs.Count -eq 0) { return }

    # Garante a chave Country/CountryCode em toda config (strict mode) e tenta inferir pelo nome
    foreach ($cfg in $Configs) {
        if (-not $cfg.ContainsKey('Country')) { $cfg['Country'] = '' }
        if (-not $cfg.ContainsKey('CountryCode')) { $cfg['CountryCode'] = '' }
        $nameCode = Get-CountryCodeFromName -Name ([string]$cfg.Name)
        if ($nameCode) {
            $cfg['CountryCode'] = $nameCode
            $cfg['Country'] = Get-CountryNamePt -Code $nameCode
        }
    }

    # Cache em disco: IP -> codigo de pais
    $cachePath = Join-Path $Script:TempDir 'geo-cache.json'
    $cache = @{}
    if (Test-Path $cachePath) {
        try {
            $raw = Get-Content $cachePath -Raw -ErrorAction Stop
            if ($raw) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($obj) {
                    foreach ($p in $obj.PSObject.Properties) {
                        if ($p.Value) { $cache["$($p.Name)"] = "$($p.Value)" }
                    }
                }
            }
        }
        catch { $cache = @{} }
    }

    # Resolve host -> IP (com cache DNS por execucao). IPs da Cloudflare (fronted) ficam sem pais.
    $hostToIp = @{}
    foreach ($cfg in $Configs) {
        $srvHost = [string]$cfg.Host
        if (-not $srvHost) { continue }
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($srvHost, [ref]$ip)) {
            $ip = $srvHost
        }
        elseif (-not $hostToIp.ContainsKey($srvHost)) {
            try {
                $addrs = [System.Net.Dns]::GetHostAddresses($srvHost)
                if ($addrs -and $addrs.Count -gt 0) { $ip = $addrs[0].ToString() }
            }
            catch { $ip = $null }
            $hostToIp[$srvHost] = $ip
        }
        else {
            $ip = $hostToIp[$srvHost]
        }
        if ($ip -and $cache.ContainsKey($ip) -and -not $cfg['Country'] -and -not (Test-CloudflareIp -IpString $ip)) {
            $cfg['CountryCode'] = $cache[$ip]
            $cfg['Country'] = Get-CountryNamePt -Code $cache[$ip]
        }
    }

    # Consulta em lote os IPs sem cache (ip-api.com, ate 100 por chamada)
    $allIps = @()
    foreach ($cfg in $Configs) {
        $srvHost = [string]$cfg.Host
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($srvHost, [ref]$ip)) { $ip = $srvHost }
        elseif ($hostToIp.ContainsKey($srvHost)) { $ip = $hostToIp[$srvHost] }
        if ($ip -and -not $cache.ContainsKey($ip) -and ($allIps -notcontains $ip) -and -not (Test-CloudflareIp -IpString $ip)) {
            $allIps += $ip
        }
    }

    for ($i = 0; $i -lt $allIps.Count; $i += 100) {
        $chunk = @($allIps[$i..([Math]::Min($i + 99, $allIps.Count - 1))])
        try {
            $body = $chunk | ConvertTo-Json
            $resp = Invoke-WebRequest -Uri 'http://ip-api.com/batch?fields=status,query,countryCode' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
            $results = $resp.Content | ConvertFrom-Json
            foreach ($r in @($results)) {
                if ($r.status -eq 'success' -and $r.query -and $r.countryCode) {
                    $cache["$($r.query)"] = "$($r.countryCode)"
                }
            }
        }
        catch { }
    }

    # Persiste cache
    if ($cache.Count -gt 0) {
        try {
            [System.IO.File]::WriteAllText($cachePath, ($cache | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { }
    }

    # Aplica resultado final
    foreach ($cfg in $Configs) {
        $srvHost = [string]$cfg.Host
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($srvHost, [ref]$ip)) { $ip = $srvHost }
        elseif ($hostToIp.ContainsKey($srvHost)) { $ip = $hostToIp[$srvHost] }
        if ($ip -and $cache.ContainsKey($ip) -and $cache[$ip] -and -not $cfg['Country'] -and -not (Test-CloudflareIp -IpString $ip)) {
            $cfg['CountryCode'] = $cache[$ip]
            $cfg['Country'] = Get-CountryNamePt -Code $cache[$ip]
        }
    }
}

function Start-V2Ray {
    param([hashtable]$Config, [int]$StabilitySeconds = 3, [bool]$Tun = $false)

    # Stop existing process
    Stop-V2Ray

    # TUN no Windows exige o driver wintun.dll ao lado do v2ray.exe
    if ($Tun -and (-not $Script:WintunDll -or -not (Test-Path $Script:WintunDll))) {
        Write-Status "wintun.dll ausente - modo TUN indisponivel" "ERROR"
        return $false
    }

    # Generate config
    if (-not (Generate-V2RayConfig -Config $Config -Tun $Tun)) {
        return $false
    }

    # Start v2ray
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Script:V2RayExe
        $psi.Arguments = "run -c `"$Script:ConfigJson`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $Script:V2RayProcess = [System.Diagnostics.Process]::Start($psi)
        $Script:CurrentConfig = $Config

        # 1) Prontidao: espera o tunel responder (poll ate ~6s, sem sleep cego)
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not ($Script:V2RayProcess -and -not $Script:V2RayProcess.HasExited)) {
                break
            }
            if (Test-V2RayTunnel -Attempts 1 -TimeoutMs 2500) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) {
            Write-Status "Tunnel check failed: $(Get-ShortName $Config.Name)" "WARN"
            Stop-V2Ray
            return $false
        }

        # 2) Estabilidade: multiplas checagens ativas espacadas (janela de $StabilitySeconds s)
        $checks = [Math]::Max(1, [int]($StabilitySeconds / 2))
        for ($i = 0; $i -lt $checks; $i++) {
            Start-Sleep -Seconds 1
            if (-not ($Script:V2RayProcess -and -not $Script:V2RayProcess.HasExited)) {
                Write-Status "v2ray process exited: $(Get-ShortName $Config.Name)" "ERROR"
                Stop-V2Ray
                return $false
            }
            if (-not (Test-V2RayTunnel -Attempts 1 -TimeoutMs 2500)) {
                Write-Status "Server instavel (caiu): $(Get-ShortName $Config.Name)" "WARN"
                Stop-V2Ray
                return $false
            }
        }

        if ($Script:V2RayProcess -and -not $Script:V2RayProcess.HasExited) {
            Write-Status "Connected to VPN: $(Get-ShortName $Config.Name)" "OK"
            Write-Status "Protocol: $($Config.Protocol) | Server: $($Config.Host):$($Config.Port) | Ping: $($Config.Ping)ms" "INFO"
            Write-Host ""
            Write-Host "  =============================================" -ForegroundColor Cyan
            Write-Host "   Configure o proxy no navegador (SwitchyOmega):" -ForegroundColor Yellow
            Write-Host "     Tipo      : SOCKS5" -ForegroundColor White
            Write-Host "     Server    : 127.0.0.1" -ForegroundColor White
            Write-Host "     Porta     : 10808" -ForegroundColor White
            Write-Host "     DNS remoto: ATIVADO (pra nao vazar DNS)" -ForegroundColor White
            Write-Host "  --------------------------------------------" -ForegroundColor Cyan
            Write-Host "   Apps sem suporte a SOCKS5 (ex: Discord):" -ForegroundColor Yellow
            Write-Host "     Use o proxy HTTP 127.0.0.1:10809" -ForegroundColor White
            Write-Host "     ou ative 'Proxy do sistema' no menu" -ForegroundColor White
            Write-Host "  =============================================" -ForegroundColor Cyan
            Write-Host ""
            return $true
        }
        else {
            Write-Status "v2ray process exited" "ERROR"
            return $false
        }
    }
    catch {
        Write-Status "Failed to start v2ray: $_" "ERROR"
        return $false
    }
}

function Stop-V2Ray {
    if ($Script:V2RayProcess) {
        try {
            if (-not $Script:V2RayProcess.HasExited) {
                $Script:V2RayProcess.Kill()
                [void]$Script:V2RayProcess.WaitForExit(5000)
            }
            $Script:V2RayProcess.Dispose()
            Write-Status "VPN disconnected" "OK"
        }
        catch {
            Write-Status "Error stopping v2ray: $_" "WARN"
        }

        $Script:V2RayProcess = $null
        $Script:CurrentConfig = $null
    }

    # Cleanup any remaining v2ray processes
    Get-Process -Name "v2ray" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function New-TlsClientHello {
    # TLS 1.2 ClientHello minimal (sem SNI) - usado p/ validar fluxo de dados no tunel
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte]0x16)                       # record: handshake
    $bw.Write([byte]3); $bw.Write([byte]1)      # record version TLS1.0
    $bw.Write([byte]0); $bw.Write([byte]0)      # record length (patch depois)
    $bw.Write([byte]1)                          # handshake: ClientHello
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]41)  # handshake length
    $bw.Write([byte]3); $bw.Write([byte]3)      # client version TLS1.2
    $rng = New-Object System.Random
    for ($i = 0; $i -lt 32; $i++) { $bw.Write([byte]$rng.Next(256)) }
    $bw.Write([byte]0)                          # session id length
    $bw.Write([byte]0); $bw.Write([byte]2)      # cipher suites length
    $bw.Write([byte]0x00); $bw.Write([byte]0x2F)   # TLS_RSA_WITH_AES_128_CBC_SHA
    $bw.Write([byte]1)                          # compression methods length
    $bw.Write([byte]0)                          # null compression
    $bw.Flush()
    $arr = $ms.ToArray()
    $bodyLen = $arr.Length - 5
    $arr[3] = [byte](($bodyLen -shr 8) -band 0xFF)
    $arr[4] = [byte]($bodyLen -band 0xFF)
    $bw.Dispose(); $ms.Dispose()
    return $arr
}

function Test-V2RayTunnel {
    param([int]$TimeoutMs = 2500, [int]$Attempts = 2)

    # Multiplos alvos (porta 443, pouco bloqueada): dominio valida DNS + roteamento, IP valida roteamento
    $targets = @(
        @{ Host = "example.com"; Port = 443 },
        @{ Host = "1.1.1.1";     Port = 443 },
        @{ Host = "8.8.8.8";     Port = 443 }
    )

    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        foreach ($t in $targets) {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.ReceiveTimeout = $TimeoutMs
                $client.SendTimeout = $TimeoutMs

                $ar = $client.BeginConnect("127.0.0.1", 10808, $null, $null)
                if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); continue }
                $client.EndConnect($ar)
                $stream = $client.GetStream()

                # SOCKS5 greeting: no auth
                $hello = [byte[]](5, 1, 0)
                $stream.Write($hello, 0, 3)
                $resp = New-Object byte[] 2
                if ($stream.Read($resp, 0, 2) -lt 2 -or $resp[1] -ne 0) { $client.Close(); continue }

                # CONNECT (ATYP=IPv4 ou domain)
                $ipParsed = $null
                $isIp = [System.Net.IPAddress]::TryParse([string]$t.Host, [ref]$ipParsed)
                $portBytes = [BitConverter]::GetBytes([UInt16]$t.Port)
                [Array]::Reverse($portBytes)

                if ($isIp) {
                    $addr = $ipParsed.GetAddressBytes()
                    $req = New-Object byte[] 10
                    $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 1
                    [Array]::Copy($addr, 0, $req, 4, 4)
                    $req[8] = $portBytes[0]; $req[9] = $portBytes[1]
                    $stream.Write($req, 0, 10)
                }
                else {
                    $domainBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$t.Host)
                    $req = New-Object byte[] (5 + 1 + $domainBytes.Length + 2)
                    $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 3
                    $req[4] = [byte]$domainBytes.Length
                    [Array]::Copy($domainBytes, 0, $req, 5, $domainBytes.Length)
                    $req[5 + $domainBytes.Length] = $portBytes[0]
                    $req[6 + $domainBytes.Length] = $portBytes[1]
                    $stream.Write($req, 0, $req.Length)
                }

                $reply = New-Object byte[] 256
                if ($stream.Read($reply, 0, 256) -lt 2 -or $reply[1] -ne 0) { $client.Close(); continue }

                # TLS ClientHello -> valida fluxo de dados real (ServerHello/Alert)
                $tlsHello = New-TlsClientHello
                $stream.Write($tlsHello, 0, $tlsHello.Length)
                $tls = New-Object byte[] 5
                $n = 0
                $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
                while ($n -lt 5 -and [DateTime]::UtcNow -lt $deadline) {
                    $r = $stream.Read($tls, $n, 5 - $n)
                    if ($r -le 0) { break }
                    $n += $r
                }
                $ok = ($n -ge 5 -and $tls[1] -eq 0x03 -and ($tls[0] -in @(0x14, 0x15, 0x16, 0x17)))
                $client.Close()
                if ($ok) { return $true }
            }
            catch {
                if ($client) { try { $client.Close() } catch {} }
            }
        }
        if ($attempt -lt ($Attempts - 1)) { Start-Sleep -Milliseconds 600 }
    }
    return $false
}

function Get-V2RayStatus {
    if (($Script:V2RayProcess) -and (-not $Script:V2RayProcess.HasExited)) {
        return $true
    }
    return $false
}

function Build-DnsQuery {
    param([string]$Name = "example.com")

    $q = New-Object System.Collections.Generic.List[byte]
    $q.Add(0x12); $q.Add(0x34)   # ID
    $q.Add(0x01); $q.Add(0x00)   # flags: RD
    $q.Add(0x00); $q.Add(0x01)   # QDCOUNT = 1
    $q.Add(0x00); $q.Add(0x00)   # ANCOUNT
    $q.Add(0x00); $q.Add(0x00)   # NSCOUNT
    $q.Add(0x00); $q.Add(0x00)   # ARCOUNT
    foreach ($label in $Name -split '\.') {
        $b = [System.Text.Encoding]::ASCII.GetBytes($label)
        $q.Add([byte]$b.Length)
        foreach ($x in $b) { $q.Add($x) }
    }
    $q.Add([byte]0)              # terminator
    $q.Add(0x00); $q.Add(0x01)   # QTYPE = A
    $q.Add(0x00); $q.Add(0x01)   # QCLASS = IN
    return $q.ToArray()
}

function Test-V2RayUdp {
    param([int]$TimeoutMs = 2500)

    # Valida UDP atraves do tunel via SOCKS5 UDP ASSOCIATE + DNS para 8.8.8.8:53
    $client = $null
    $udp = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $ar = $client.BeginConnect("127.0.0.1", 10808, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); return $false }
        $client.EndConnect($ar)
        $stream = $client.GetStream()

        $hello = [byte[]](5, 1, 0)
        $stream.Write($hello, 0, 3)
        $resp = New-Object byte[] 2
        if ($stream.Read($resp, 0, 2) -lt 2 -or $resp[1] -ne 0) { $client.Close(); return $false }

        # UDP ASSOCIATE (CMD=3), ATYP=IPv4, 0.0.0.0:0
        $req = New-Object byte[] 10
        $req[0] = 5; $req[1] = 3; $req[2] = 0; $req[3] = 1
        $stream.Write($req, 0, 10)
        $reply = New-Object byte[] 256
        if ($stream.Read($reply, 0, 256) -lt 4 -or $reply[1] -ne 0) { $client.Close(); return $false }

        $atyp = $reply[3]
        $bndIp = ""; $bndPort = 0
        if ($atyp -eq 1) {
            $bndIp = "$($reply[4]).$($reply[5]).$($reply[6]).$($reply[7])"
            $bndPort = ([int]$reply[8] -shl 8) -bor [int]$reply[9]
        }
        elseif ($atyp -eq 3) {
            $len = [int]$reply[4]
            $bndIp = [System.Text.Encoding]::ASCII.GetString($reply, 5, $len)
            $bndPort = ([int]$reply[5 + $len] -shl 8) -bor [int]$reply[6 + $len]
        }
        else { $client.Close(); return $false }
        if (-not $bndIp -or $bndPort -le 0) { $client.Close(); return $false }

        $dns = Build-DnsQuery
        $hdr = New-Object byte[] (10 + $dns.Length)
        $dst = [System.Net.IPAddress]::Parse("8.8.8.8").GetAddressBytes()
        $hdr[3] = 1
        [Array]::Copy($dst, 0, $hdr, 4, 4)
        $hdr[8] = 0; $hdr[9] = 53
        [Array]::Copy($dns, 0, $hdr, 10, $dns.Length)

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($bndIp, $bndPort)
        [void]$udp.Send($hdr, $hdr.Length)
        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $udp.Receive([ref]$remoteEp)
        $ok = ($data -and $data.Length -gt 0)
        $udp.Close(); $client.Close()
        return $ok
    }
    catch {
        if ($udp) { try { $udp.Close() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
    return $false
}

# ============================================================
# SYSTEM PROXY (WinINET)
# ============================================================

$Script:ProxyActive = $false
$Script:ProxyBackupEnable = $null
$Script:ProxyBackupServer = $null

if (-not ("SettVPN.WinInetNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class WinInetNative {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(int hInternet, int dwOption, int lpBuffer, int dwBufferLength);
}
"@
}

function Set-ProxyRegistry {
    param([int]$Enable, [string]$Server = "")

    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $path -Name ProxyEnable -Value $Enable
    if ($Server) {
        Set-ItemProperty -Path $path -Name ProxyServer -Value $Server
    }

    try {
        [WinInetNative]::InternetSetOption(0, 39, 0, 0) | Out-Null   # INTERNET_OPTION_SETTINGS_CHANGED
        [WinInetNative]::InternetSetOption(0, 37, 0, 0) | Out-Null   # INTERNET_OPTION_REFRESH
    }
    catch { }
}

function Enable-SystemProxy {
    if (-not $Script:ProxyActive) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $Script:ProxyBackupEnable = (Get-ItemProperty -Path $path -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        $Script:ProxyBackupServer = (Get-ItemProperty -Path $path -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    }
    Set-ProxyRegistry -Enable 1 -Server "http=127.0.0.1:10809;https=127.0.0.1:10809;socks=127.0.0.1:10808"
    $Script:ProxyActive = $true
    Write-Status "System proxy enabled: http=127.0.0.1:10809 / socks=127.0.0.1:10808" "OK"
}

function Disable-SystemProxy {
    if ($null -ne $Script:ProxyBackupEnable) {
        Set-ProxyRegistry -Enable $Script:ProxyBackupEnable -Server ([string]$Script:ProxyBackupServer)
    }
    else {
        Set-ProxyRegistry -Enable 0
    }
    $Script:ProxyActive = $false
    Write-Status "System proxy disabled" "OK"
}

function Toggle-SystemProxy {
    if ($Script:ProxyActive) { Disable-SystemProxy } else { Enable-SystemProxy }
}

# ============================================================
# MENU FUNCTIONS
# ============================================================

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host "           SETT VPN MANAGER" -ForegroundColor Cyan
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Source: abc-configs (GitHub - Auto-Update)" -ForegroundColor DarkGray
    Write-Host ""

    if (Get-V2RayStatus) {
        Write-Host "  Status: " -NoNewline
        Write-Host "CONNECTED" -ForegroundColor Green
        Write-Host "  Server: $($Script:CurrentConfig.Name)" -ForegroundColor Yellow
        Write-Host "  Ping  : $($Script:CurrentConfig.Ping)ms" -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        Write-Host "  Status: " -NoNewline
        Write-Host "DISCONNECTED" -ForegroundColor Red
        Write-Host ""
    }
}

function Show-Menu {
    Write-Host "  [1] Connect VPN (Auto - Lowest Ping)" -ForegroundColor White
    Write-Host "  [2] Change VPN (Manual Selection)" -ForegroundColor White
    Write-Host "  [3] Disconnect VPN" -ForegroundColor White
    Write-Host "  [4] Toggle System Proxy ($(if ($Script:ProxyActive) { 'ON' } else { 'OFF' }))" -ForegroundColor White
    Write-Host "  [5] Exit" -ForegroundColor White
    Write-Host ""
    Write-Host "  Select option: " -NoNewline -ForegroundColor Cyan
}

function Menu-ConnectVPN {
    Write-Status "Loading VPN servers..." "INFO"
    $configs = Get-AllConfigs

    if (-not $configs -or $configs.Count -eq 0) {
        Write-Status "No configs found in README.md" "ERROR"
        Read-Host "Press Enter to continue"
        return
    }

    $sorted = Get-ConfigsWithPing -Configs $configs

    if (-not $sorted -or $sorted.Count -eq 0) {
        Write-Status "No reachable servers found" "ERROR"
        Read-Host "Press Enter to continue"
        return
    }

    Write-Status "Attempting connection with lowest ping servers..." "INFO"

    foreach ($config in $sorted) {
        Write-Status "Trying: $($config.Name) ($($config.Ping)ms)" "INFO"

        if (Start-V2Ray -Config $config) {
            Write-Status "Successfully connected!" "OK"
            Read-Host "Press Enter to continue"
            return
        }
        else {
            Write-Status "Failed, trying next server..." "WARN"
        }
    }

    Write-Status "All servers failed to connect" "ERROR"
    Read-Host "Press Enter to continue"
}

function Menu-ChangeVPN {
    Write-Status "Loading VPN servers..." "INFO"
    $configs = Get-AllConfigs

    if (-not $configs -or $configs.Count -eq 0) {
        Write-Status "No configs found in README.md" "ERROR"
        Read-Host "Press Enter to continue"
        return
    }

    $sorted = Get-ConfigsWithPing -Configs $configs

    if (-not $sorted -or $sorted.Count -eq 0) {
        Write-Status "No reachable servers found" "ERROR"
        Read-Host "Press Enter to continue"
        return
    }

    Clear-Host
    Write-Host ""
    Write-Host "  Available VPN Servers:" -ForegroundColor Cyan
    Write-Host "  ======================" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $cfg = $sorted[$i]
        $num = $i + 1
        Write-Host "  [$num] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($cfg.Name) " -NoNewline
        Write-Host "(Ping: $($cfg.Ping)ms)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  [0] Cancel" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Select server number: " -NoNewline -ForegroundColor Cyan

    $choice = Read-Host

    if ($choice -eq "0") {
        return
    }

    $index = [int]$choice - 1

    if (($index -ge 0) -and ($index -lt $sorted.Count)) {
        $selected = $sorted[$index]
        Write-Status "Connecting to: $($selected.Name)" "INFO"

        if (Start-V2Ray -Config $selected) {
            Write-Status "Successfully connected!" "OK"
        }
        else {
            Write-Status "Connection failed" "ERROR"
        }
    }
    else {
        Write-Status "Invalid selection" "ERROR"
    }

    Read-Host "Press Enter to continue"
}

function Menu-DisconnectVPN {
    Stop-V2Ray
    Disable-SystemProxy
    Read-Host "Press Enter to continue"
}

# ============================================================
# MAIN LOOP
# ============================================================

function Start-SettVPN {
    Initialize-Environment

    if (-not (Extract-V2Ray)) {
        Write-Status "Failed to initialize v2ray" "ERROR"
        Read-Host "Press Enter to exit"
        return
    }

    while ($true) {
        Show-Banner
        Show-Menu

        $choice = Read-Host

        switch ($choice) {
            "1" { Menu-ConnectVPN }
            "2" { Menu-ChangeVPN }
            "3" { Menu-DisconnectVPN }
            "4" { Toggle-SystemProxy }
            "5" {
                Stop-V2Ray
                Disable-SystemProxy
                Write-Status "Exiting SettVPN..." "INFO"
                return
            }
            default {
                Write-Status "Invalid option" "WARN"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ============================================================
# ENTRY POINT
# ============================================================

if ($Console) {
    try {
        Start-SettVPN
    }
    catch {
        Write-Status "Fatal error: $_" "ERROR"
        Read-Host "Press Enter to exit"
    }
    finally {
        Stop-V2Ray
        Disable-SystemProxy
    }
}
else {
    . (Join-Path $Script:ScriptDir "SettVPN_Gui.ps1")
    Start-SettVPN-Gui
}

