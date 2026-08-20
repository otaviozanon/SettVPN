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
$Script:LastFailReason = ""
$Script:TunStopFile = $null
$Script:AbcConfigsUrl = "https://raw.githubusercontent.com/FreeFolksOn/abc-configs-free-vpn-proxy-list/main/README.md"
$Script:SubConfigsUrl = "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"
$Script:Sub2ConfigsUrl = "https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list.txt"

# ============================================================
# V2RAY - extraido pelo launcher (SettVPN.exe) para %TEMP%\SettVPN\v2ray.exe
# ============================================================

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
    Restore-OrphanProxy
}

function Extract-V2Ray {
    if (Test-Path $Script:V2RayExe) {
        Write-Status "v2ray.exe already extracted" "INFO"
        return $true
    }

    Write-Status "v2ray.exe not found. Run via SettVPN.exe." "ERROR"
    return $false
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

            $guid = [guid]::Empty
            if (-not [guid]::TryParse([string]$json.id, [ref]$guid)) {
                Write-Status "Skipping VMess config with non-UUID id: $($json.id)" "WARN"
                return $null
            }

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
    return Get-CachedContent -Url $Script:AbcConfigsUrl -Cache $Script:ReadmeCache -Label "abc-configs"
}

function Get-CachedContent {
    param([string]$Url, [string]$Cache, [string]$Label)

    if (Test-Path $Cache) {
        $cacheAge = (Get-Date) - (Get-Item $Cache).LastWriteTime
        if ($cacheAge.TotalMinutes -lt 10) {
            Write-Status "Using cached $Label (updated $([math]::Round($cacheAge.TotalMinutes, 1)) min ago)" "INFO"
            return Get-Content $Cache -Raw
        }
    }

    try {
        Write-Status "Downloading $Label..." "INFO"
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $content = $response.Content

        Set-Content -Path $Cache -Value $content -Encoding UTF8
        Write-Status "Downloaded and cached $Label" "OK"
        return $content
    }
    catch {
        Write-Status "Failed to download ${Label}: $_" "WARN"

        if (Test-Path $Cache) {
            $cacheAge = (Get-Date) - (Get-Item $Cache).LastWriteTime
            Write-Status "Using cached $Label (updated $([math]::Round($cacheAge.TotalHours, 1)) hours ago)" "WARN"
            return Get-Content $Cache -Raw
        }
        return $null
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

    return Get-CachedContent -Url $Url -Cache $Cache -Label $Label
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

function Get-ServerPool {
    param([bool]$Filtered = $false, [hashtable]$BadServers = $null)

    $all = Get-AllConfigs
    if (-not $all -or $all.Count -eq 0) { return $null }

    if ($BadServers -and $BadServers.Count -gt 0) {
        $now = [DateTime]::Now
        $all = @($all | Where-Object {
            $k = "$($_.Host):$($_.Port)"
            -not ($BadServers.ContainsKey($k) -and (($now - $BadServers[$k]).TotalMinutes -lt 5))
        })
    }

    $sorted = Get-ConfigsWithPing -Configs $all
    if (-not $sorted -or $sorted.Count -eq 0) { return $null }

    if ($Filtered) {
        $stable = @(Scan-StableServers -Configs $sorted)
        Resolve-Countries -Configs $stable
        return $stable
    }

    Resolve-Countries -Configs $sorted
    return @($sorted)
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
    param([hashtable]$Config, [bool]$Tun = $false, [int]$SocksPort = 10808, [int]$HttpPort = 10809, [string]$ConfigPath = "", [string]$LogPath = "")

    if (-not $ConfigPath) { $ConfigPath = $Script:ConfigJson }
    if (-not $LogPath) { $LogPath = $Script:XrayLog }

    $configObj = @{
        log = @{
            loglevel = "info"
            error    = $LogPath
        }
        inbounds = @(
            @{
                port = $SocksPort
                protocol = "socks"
                settings = @{
                    auth = "noauth"
                    udp = $true
                }
            },
            @{
                port = $HttpPort
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
        $net = [string]$Config.Network
        if ($net -and $net -ne "tcp") {
            Write-Status "Skipping unsupported VMess transport: $net" "WARN"
            return $false
        }
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
                network = if ($net) { $net } else { "tcp" }
            }
        }
        $configObj.outbounds += $outbound
    }

    # Save to file
    try {
        $json = $configObj | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Status "Generated v2ray config: $ConfigPath" "OK"
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

    # VMess guarda o transport em Network (nao em Params); so tcp e suportado.
    if ($Config['Protocol'] -eq 'vmess') {
        $net = [string]$Config['Network']
        if ($net -and $net -ne 'tcp') { return $false }
    }

    return $true
}

function Get-FuncSource {
    # Reconstroi o codigo-fonte das funcoes (p/ redefinir em runspaces paralelos).
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script:ScriptFile, [ref]$tokens, [ref]$errs)
    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    return (($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n")
}

function Test-ServerStable {
    param([hashtable]$Config, [int]$SocksPort = 10808, [int]$HttpPort = 10809, [string]$ConfigPath = "", [string]$LogPath = "", [int]$StabilitySeconds = 6)

    # Teste isolado (porta/config/processo proprios) - nao toca em $Script:V2RayProcess/CurrentConfig.
    if (-not $ConfigPath) { $ConfigPath = Join-Path $Script:TempDir "config-scan-$SocksPort.json" }
    if (-not $LogPath) { $LogPath = Join-Path $Script:TempDir "xray-scan-$SocksPort.log" }

    if (-not (Generate-V2RayConfig -Config $Config -Tun $false -SocksPort $SocksPort -HttpPort $HttpPort -ConfigPath $ConfigPath -LogPath $LogPath)) {
        return $false
    }

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Script:V2RayExe
        $psi.Arguments = "run -c `"$ConfigPath`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # 1) prontidao: espera o tunel responder (poll ate ~6s, sem sleep cego)
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($proc.HasExited) { break }
            if (Test-V2RayTunnel -Attempts 1 -TimeoutMs 2500 -SocksPort $SocksPort) { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { return $false }

        # 2) estabilidade: multiplas checagens espacadas
        $checks = [Math]::Max(1, [int]($StabilitySeconds / 2))
        for ($i = 0; $i -lt $checks; $i++) {
            Start-Sleep -Seconds 1
            if ($proc.HasExited) { return $false }
            if (-not (Test-V2RayTunnel -Attempts 1 -TimeoutMs 2500 -SocksPort $SocksPort)) { return $false }
        }

        # 3) UDP (Discord/voz, jogos, DNS usam UDP)
        return (Test-V2RayUdp -TimeoutMs 2500 -SocksPort $SocksPort)
    }
    catch {
        return $false
    }
    finally {
        if ($proc) {
            try {
                if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(3000) }
                $proc.Dispose()
            }
            catch { }
        }
    }
}

function Scan-StableServers {
    param([array]$Configs, [int]$MaxToTest = 25, [int]$StabilitySeconds = 6, [int]$MinStable = 10, [int]$Concurrency = 5)

    $stable = @()
    $tested = 0
    $total = [Math]::Min($Configs.Count, $MaxToTest)
    if ($total -le 0) { return $stable }
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Sync) {
        $Sync.ScanTotal = $total; $Sync.ScanTested = 0; $Sync.ScanStart = [DateTime]::Now
        $Sync.ScanDeadline = [DateTime]::Now.AddSeconds($total * 30)
    }

    # Limpa arquivos temporarios do scan anterior (evita acumular no %TEMP%)
    try {
        Get-ChildItem $Script:TempDir -Filter "config-scan-*.json" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem $Script:TempDir -Filter "xray-scan-*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }

    $funcSource = Get-FuncSource
    $offset = 0
    while ($offset -lt $total -and ($MinStable -le 0 -or $stable.Count -lt $MinStable)) {
        $batch = @()
        for ($j = 0; $j -lt $Concurrency -and ($offset + $j) -lt $total; $j++) {
            $batch += $Configs[$offset + $j]
        }
        if ($batch.Count -eq 0) { break }

        # Sobe N instancias de xray em runspaces paralelos (cada uma com porta propria)
        $results = [hashtable]::Synchronized(@{})
        $handles = @()
        $powershells = @()
        $runspaces = @()
        for ($j = 0; $j -lt $batch.Count; $j++) {
            $socks = 10808 + ($j * 10)
            $http = $socks + 1

            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $rs.SessionStateProxy.SetVariable('scanFuncSource', $funcSource)
            $rs.SessionStateProxy.SetVariable('scanCfg', $batch[$j])
            $rs.SessionStateProxy.SetVariable('scanSocks', $socks)
            $rs.SessionStateProxy.SetVariable('scanHttp', $http)
            $rs.SessionStateProxy.SetVariable('scanStab', $StabilitySeconds)
            $rs.SessionStateProxy.SetVariable('scanResults', $results)
            $rs.SessionStateProxy.SetVariable('scanSlot', $j)
            $rs.SessionStateProxy.SetVariable('scanTempDir', $Script:TempDir)
            $rs.SessionStateProxy.SetVariable('scanV2RayExe', $Script:V2RayExe)

            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript(@'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$Script:TempDir = $scanTempDir
$Script:V2RayExe = $scanV2RayExe
Invoke-Expression $scanFuncSource
function Write-Status { param([string]$Message, [string]$Type = 'INFO') }
$scanResults[$scanSlot] = Test-ServerStable -Config $scanCfg -SocksPort $scanSocks -HttpPort $scanHttp -StabilitySeconds $scanStab
'@)
            $handles += $ps.BeginInvoke()
            $powershells += $ps
            $runspaces += $rs
        }

        # Espera todos do lote terminarem
        $done = $false
        while (-not $done) {
            $done = $true
            foreach ($h in $handles) {
                if (-not $h.IsCompleted) { $done = $false; break }
            }
            if (-not $done) { Start-Sleep -Milliseconds 100 }
        }
        for ($j = 0; $j -lt $handles.Count; $j++) {
            try { $powershells[$j].EndInvoke($handles[$j]) } catch { }
        }
        foreach ($rs in $runspaces) { try { $rs.Dispose() } catch { } }
        foreach ($ps in $powershells) { try { $ps.Dispose() } catch { } }

        # Coleta resultados na ordem do lote
        for ($j = 0; $j -lt $batch.Count; $j++) {
            $tested++
            $cfg = $batch[$j]
            if ($Sync) { $Sync.ScanTested = $tested; $Sync.Progress = [int](($tested / $total) * 100) }

            if ($results.ContainsKey($j) -and $results[$j]) {
                $stable += $cfg
                Write-Status "Estavel (TCP+UDP): $(Get-ShortName $cfg.Name)" "OK"
                if ($MinStable -gt 0 -and $stable.Count -ge $MinStable) {
                    Write-Status "Encerrando scan: $($stable.Count) servidores estaveis" "OK"
                    break
                }
            }
            else {
                Write-Status "Descartado: $(Get-ShortName $cfg.Name)" "WARN"
            }

            # ETA adaptativo: media real de tempo por servidor x servidores restantes
            if ($Sync) {
                $eta = Get-ScanEtaSeconds -ElapsedSeconds $scanSw.Elapsed.TotalSeconds -Total $total -Tested $tested
                $newDeadline = [DateTime]::Now.AddSeconds($eta)
                if ($Sync.ScanDeadline -eq [DateTime]::MinValue -or $newDeadline -lt $Sync.ScanDeadline) {
                    $Sync.ScanDeadline = $newDeadline
                }
            }
        }

        $offset += $batch.Count
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
    if (-not (Get-Variable -Name 'CountryMap' -Scope Script -ErrorAction SilentlyContinue)) {
        $Script:CountryMap = @{
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
    }
    $map = $Script:CountryMap
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

function Resolve-DnsParallel {
    param([string[]]$Hosts)

    $result = @{}
    if (-not $Hosts -or $Hosts.Count -eq 0) { return $result }

    $pending = New-Object 'System.Collections.Generic.List[object]'
    foreach ($h in $Hosts) {
        try {
            $ar = [System.Net.Dns]::BeginGetHostAddresses($h, $null, $null)
            $pending.Add(@{ Host = $h; Ar = $ar })
        }
        catch { }
    }
    foreach ($item in $pending) {
        try {
            $addrs = [System.Net.Dns]::EndGetHostAddresses($item.Ar)
            if ($addrs -and $addrs.Count -gt 0) { $result[$item.Host] = $addrs[0].ToString() }
        }
        catch { }
    }
    return $result
}

function Resolve-Countries {
    param([array]$Configs)

    if (-not $Configs -or $Configs.Count -eq 0) { return }

    # Garante a chave Country/CountryCode (strict mode), infere pelo nome e coleta hosts p/ DNS
    $hosts = @{}
    foreach ($cfg in $Configs) {
        if (-not $cfg.ContainsKey('Country')) { $cfg['Country'] = '' }
        if (-not $cfg.ContainsKey('CountryCode')) { $cfg['CountryCode'] = '' }
        $nameCode = Get-CountryCodeFromName -Name ([string]$cfg.Name)
        if ($nameCode) {
            $cfg['CountryCode'] = $nameCode
            $cfg['Country'] = Get-CountryNamePt -Code $nameCode
        }
        $srvHost = [string]$cfg.Host
        if ($srvHost) {
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse($srvHost, [ref]$ip) -and -not $hosts.ContainsKey($srvHost)) {
                $hosts[$srvHost] = $srvHost
            }
        }
    }

    # DNS em paralelo (1 round-trip p/ todos os hosts, em vez de serial)
    $hostToIp = Resolve-DnsParallel -Hosts @($hosts.Keys)

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

    # IPs sem cache (HashSet: O(1), sem o -notcontains O(n^2) original)
    $missing = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($cfg in $Configs) {
        $ip = $null
        $srvHost = [string]$cfg.Host
        if ([System.Net.IPAddress]::TryParse($srvHost, [ref]$ip)) { }
        elseif ($hostToIp.ContainsKey($srvHost)) { $ip = $hostToIp[$srvHost] }
        if (-not $ip -or $cfg['Country'] -or (Test-CloudflareIp -IpString $ip)) { continue }
        if ($cache.ContainsKey($ip)) {
            $cfg['CountryCode'] = $cache[$ip]
            $cfg['Country'] = Get-CountryNamePt -Code $cache[$ip]
        }
        else {
            [void]$missing.Add($ip)
        }
    }

    # Consulta em lote os IPs sem cache (ip-api.com, ate 100 por chamada)
    $missingList = @($missing)
    for ($i = 0; $i -lt $missingList.Count; $i += 100) {
        $chunk = @($missingList[$i..([Math]::Min($i + 99, $missingList.Count - 1))])
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
        if ($cfg['Country']) { continue }
        $ip = $null
        $srvHost = [string]$cfg.Host
        if ([System.Net.IPAddress]::TryParse($srvHost, [ref]$ip)) { }
        elseif ($hostToIp.ContainsKey($srvHost)) { $ip = $hostToIp[$srvHost] }
        if (-not $ip -or -not $cache.ContainsKey($ip) -or -not $cache[$ip]) { continue }
        if (Test-CloudflareIp -IpString $ip) { continue }
        $cfg['CountryCode'] = $cache[$ip]
        $cfg['Country'] = Get-CountryNamePt -Code $cache[$ip]
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-V2Ray {
    param([hashtable]$Config, [int]$StabilitySeconds = 3, [bool]$Tun = $false)

    $Script:LastFailReason = ""

    # Stop existing process
    Stop-V2Ray

    # TUN no Windows exige o driver wintun.dll ao lado do v2ray.exe
    if ($Tun -and (-not $Script:WintunDll -or -not (Test-Path $Script:WintunDll))) {
        $Script:LastFailReason = "wintun.dll ausente - modo TUN indisponivel"
        Write-Status $Script:LastFailReason "ERROR"
        return $false
    }

    # Generate config
    if (-not (Generate-V2RayConfig -Config $Config -Tun $Tun)) {
        $Script:LastFailReason = "Falha ao gerar config do xray"
        return $false
    }

    # Start v2ray
    try {
        $Script:TunStopFile = $null
        if ($Tun -and -not (Test-IsAdmin)) {
            # TUN exige admin (adaptador wintun). Sobe um supervisor elevado que
            # gerencia o xray; o resto do app segue sem privilegios.
            $supervisorScript = @'
param($xray, $config, $stopFile)
$p = Start-Process -FilePath $xray -ArgumentList "run -c `"$config`"" -PassThru -NoNewWindow
while (-not (Test-Path $stopFile) -and -not $p.HasExited) { Start-Sleep -Milliseconds 300 }
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
'@
            $stopFile = Join-Path $Script:TempDir "tun-stop.txt"
            Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
            $supervisorPath = Join-Path $Script:TempDir "tun-supervisor.ps1"
            Set-Content -Path $supervisorPath -Value $supervisorScript -Encoding UTF8
            $supervisor = Start-Process powershell -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$supervisorPath`" -xray `"$($Script:V2RayExe)`" -config `"$($Script:ConfigJson)`" -stopFile `"$stopFile`""
            $Script:V2RayProcess = $supervisor
            $Script:TunStopFile = $stopFile
        }
        else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Script:V2RayExe
            $psi.Arguments = "run -c `"$Script:ConfigJson`""
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $Script:V2RayProcess = [System.Diagnostics.Process]::Start($psi)
        }
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
            $Script:LastFailReason = "Tunnel check failed: $(Get-ShortName $Config.Name)$(Get-FailReason)"
            Write-Status $Script:LastFailReason "WARN"
            Stop-V2Ray
            return $false
        }

        # 1.5) TUN: confirma que o adaptador + rota foram criados (evita "conectado" falso com vazamento)
        if ($Tun) {
            $tunOk = $false
            for ($i = 0; $i -lt 4; $i++) {
                if (Test-V2RayTun) { $tunOk = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $tunOk) {
                $tail = Get-XrayLogTail
                $reason = if ($tail) { "Log: $tail" } else { "driver wintun ausente?" }
                $Script:LastFailReason = "TUN falhou - trafego vazando. $reason"
                Write-Status $Script:LastFailReason "ERROR"
                Stop-V2Ray
                return $false
            }
        }

        # 2) Estabilidade: multiplas checagens ativas espacadas (janela de $StabilitySeconds s)
        $checks = [Math]::Max(1, [int]($StabilitySeconds / 2))
        for ($i = 0; $i -lt $checks; $i++) {
            Start-Sleep -Seconds 1
            if (-not ($Script:V2RayProcess -and -not $Script:V2RayProcess.HasExited)) {
                $Script:LastFailReason = "v2ray process exited: $(Get-ShortName $Config.Name)$(Get-FailReason)"
                Write-Status $Script:LastFailReason "ERROR"
                Stop-V2Ray
                return $false
            }
            if (-not (Test-V2RayTunnel -Attempts 1 -TimeoutMs 2500)) {
                $Script:LastFailReason = "Server instavel (caiu): $(Get-ShortName $Config.Name)$(Get-FailReason)"
                Write-Status $Script:LastFailReason "WARN"
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
        $Script:LastFailReason = "Failed to start v2ray: $_"
        Write-Status $Script:LastFailReason "ERROR"
        return $false
    }
}

function Stop-V2Ray {
    $ownPid = 0
    if ($Script:V2RayProcess) {
        $ownPid = $Script:V2RayProcess.Id
        try {
            if (-not $Script:V2RayProcess.HasExited) {
                if ($Script:TunStopFile) {
                    # xray elevado via supervisor: sinaliza para o supervisor encerrar o xray e sair
                    try { New-Item -Path $Script:TunStopFile -ItemType File -Force | Out-Null } catch { }
                    [void]$Script:V2RayProcess.WaitForExit(5000)
                }
                else {
                    $Script:V2RayProcess.Kill()
                    [void]$Script:V2RayProcess.WaitForExit(5000)
                }
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

    if ($Script:TunStopFile) {
        try { Remove-Item $Script:TunStopFile -Force -ErrorAction SilentlyContinue } catch { }
        $Script:TunStopFile = $null
    }

    # Mata apenas o NOSSO binario (PID rastreado ou caminho exato), nunca v2ray de terceiros.
    try {
        Get-Process -Name "v2ray" -ErrorAction SilentlyContinue |
            Where-Object { ($_.Id -eq $ownPid) -or ($_.Path -eq $Script:V2RayExe) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch { }
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

function Test-V2RayTun {
    # Verifica se o adaptador TUN foi criado e se a rota padrao passa por ele.
    # Sem isso o app reportaria "conectado (TUN ON)" com trafego vazando direto.
    try {
        $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.InterfaceDescription -match 'Wintun|WireGuard' -or $_.Name -match 'Wintun'
        } | Select-Object -First 1
        if (-not $adapter) { return $false }

        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.ifIndex -eq $adapter.ifIndex }
        return ($null -ne $route)
    }
    catch {
        return $false
    }
}

function Get-XrayLogTail {
    param([int]$Lines = 40)

    if (-not $Script:XrayLog -or -not (Test-Path $Script:XrayLog)) { return "" }
    try {
        $tail = Get-Content $Script:XrayLog -Tail $Lines -ErrorAction Stop
        $reasons = @()
        foreach ($line in $tail) {
            $ms = [regex]::Matches($line, '\b\d{3}\s+(?:Conflict|Not Found|Bad Request|Bad Gateway|Moved Permanently|Moved Temporarily|Forbidden|Unauthorized|Service Unavailable|Internal Server Error|Gateway Timeout|Too Many Requests)|bad handshake|unexpected EOF|connection refused|i/o timeout|forcibly closed|wintun|tun2socks')
            foreach ($m in $ms) {
                $r = $m.Value.Trim()
                if ($r -and ($reasons -notcontains $r)) { $reasons += $r }
            }
        }
        if ($reasons.Count -gt 0) {
            $msg = ($reasons -join " | ")
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + "..." }
            return $msg
        }
        $generic = @($tail | Where-Object { $_ -match '\[(Error|Warning)\]' } | Select-Object -Last 1)
        if ($generic.Count -gt 0) {
            $msg = ($generic[0] -replace '^.*?\]\s*', '')
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + "..." }
            return $msg
        }
        return ""
    }
    catch {
        return ""
    }
}

function Get-FailReason {
    $tail = Get-XrayLogTail
    if ($tail) { return " | $tail" }
    return ""
}

function Test-V2RayTunnel {
    param([int]$TimeoutMs = 2500, [int]$Attempts = 2, [int]$SocksPort = 10808)

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

                $ar = $client.BeginConnect("127.0.0.1", $SocksPort, $null, $null)
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
    param([int]$TimeoutMs = 2500, [int]$SocksPort = 10808)

    # Valida UDP atraves do tunel via SOCKS5 UDP ASSOCIATE + DNS para 8.8.8.8:53
    $client = $null
    $udp = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $ar = $client.BeginConnect("127.0.0.1", $SocksPort, $null, $null)
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
$Script:ProxyBackupFile = Join-Path $Script:TempDir "proxy-backup.json"

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

function Save-ProxyBackup {
    param([int]$Enable, [string]$Server)
    try {
        $obj = @{ Enable = $Enable; Server = [string]$Server }
        [System.IO.File]::WriteAllText($Script:ProxyBackupFile, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Clear-ProxyBackup {
    try { if (Test-Path $Script:ProxyBackupFile) { Remove-Item $Script:ProxyBackupFile -Force -ErrorAction Stop } } catch { }
}

function Restore-OrphanProxy {
    # Se o app caiu numa execucao anterior com o proxy ligado, o backup em disco
    # continua e o registro aponta p/ 127.0.0.1 morto -> restaura e limpa.
    if (-not (Test-Path $Script:ProxyBackupFile)) { return }
    try {
        $obj = Get-Content $Script:ProxyBackupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($obj) {
            Set-ProxyRegistry -Enable ([int]$obj.Enable) -Server ([string]$obj.Server)
            Write-Status "Proxy do sistema restaurado (execucao anterior caiu com proxy ativo)" "WARN"
        }
    }
    catch { }
    Clear-ProxyBackup
}

function Enable-SystemProxy {
    if (-not $Script:ProxyActive) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $Script:ProxyBackupEnable = (Get-ItemProperty -Path $path -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        $Script:ProxyBackupServer = (Get-ItemProperty -Path $path -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
        Save-ProxyBackup -Enable ([int]$Script:ProxyBackupEnable) -Server ([string]$Script:ProxyBackupServer)
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
    Clear-ProxyBackup
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
            if ($Script:LastFailReason) { Write-Status "Falhou: $Script:LastFailReason" "WARN" }
            else { Write-Status "Failed, trying next server..." "WARN" }
        }
    }

    if ($Script:LastFailReason) { Write-Status "Todos falharam - ultima causa: $Script:LastFailReason" "ERROR" }
    else { Write-Status "All servers failed to connect" "ERROR" }
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
            if ($Script:LastFailReason) { Write-Status "Falhou: $Script:LastFailReason" "ERROR" }
            else { Write-Status "Connection failed" "ERROR" }
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

