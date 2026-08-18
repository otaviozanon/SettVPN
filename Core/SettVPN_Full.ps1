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
$Script:ConfigJson = Join-Path $Script:TempDir "config.json"
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
            if ($parsed) { $configs += $parsed }
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
                if ($parsed) { $configs += $parsed }
            }
        }
        Write-Status "$($src.Label): $count found" "INFO"
    }

    Write-Status "Found $($configs.Count) total configs" "INFO"
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
    param([hashtable]$Config)

    $configObj = @{
        log = @{
            loglevel = "warning"
        }
        inbounds = @(
            @{
                port = 10808
                protocol = "socks"
                settings = @{
                    auth = "noauth"
                    udp = $true
                }
            }
        )
        outbounds = @()
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

function Start-V2Ray {
    param([hashtable]$Config)

    # Stop existing process
    Stop-V2Ray

    # Generate config
    if (-not (Generate-V2RayConfig -Config $Config)) {
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

        Start-Sleep -Seconds 2

        if (($Script:V2RayProcess) -and (-not $Script:V2RayProcess.HasExited)) {
            if (-not (Test-V2RayTunnel)) {
                Write-Status "Tunnel check failed: $($Config.Name)" "WARN"
                Stop-V2Ray
                return $false
            }
            Write-Status "Connected to VPN: $($Config.Name)" "OK"
            Write-Status "Protocol: $($Config.Protocol) | Server: $($Config.Host):$($Config.Port) | Ping: $($Config.Ping)ms" "INFO"
            Write-Host ""
            Write-Host "  =============================================" -ForegroundColor Cyan
            Write-Host "   Configure o proxy no navegador (SwitchyOmega):" -ForegroundColor Yellow
            Write-Host "     Tipo      : SOCKS5" -ForegroundColor White
            Write-Host "     Server    : 127.0.0.1" -ForegroundColor White
            Write-Host "     Porta     : 10808" -ForegroundColor White
            Write-Host "     DNS remoto: ATIVADO (pra nao vazar DNS)" -ForegroundColor White
            Write-Host "  =============================================" -ForegroundColor Cyan
            Write-Host ""
            return $true
        }
        else {
            Write-Status "v2ray process exited immediately" "ERROR"
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
                $Script:V2RayProcess.WaitForExit(5000)
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

function Test-V2RayTunnel {
    param([int]$TimeoutMs = 4000)

    $targetIp = "1.1.1.1"
    $targetPort = 443

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.ReceiveTimeout = $TimeoutMs
            $client.SendTimeout = $TimeoutMs

            $ar = $client.BeginConnect("127.0.0.1", 10808, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); Start-Sleep -Milliseconds 1200; continue }
            $client.EndConnect($ar)

            $stream = $client.GetStream()

            # SOCKS5 greeting: no auth
            $hello = [byte[]](5, 1, 0)
            $stream.Write($hello, 0, 3)
            $resp = New-Object byte[] 2
            if ($stream.Read($resp, 0, 2) -lt 2 -or $resp[1] -ne 0) { $client.Close(); Start-Sleep -Milliseconds 1200; continue }

            # CONNECT 1.1.1.1:443
            $addr = [System.Net.IPAddress]::Parse($targetIp).GetAddressBytes()
            $portBytes = [BitConverter]::GetBytes([UInt16]$targetPort)
            [Array]::Reverse($portBytes)

            $req = New-Object byte[] 10
            $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 1
            [Array]::Copy($addr, 0, $req, 4, 4)
            $req[8] = $portBytes[0]; $req[9] = $portBytes[1]
            $stream.Write($req, 0, 10)

            $reply = New-Object byte[] 10
            if ($stream.Read($reply, 0, 10) -lt 2) { $client.Close(); Start-Sleep -Milliseconds 1200; continue }

            $ok = ($reply[0] -eq 5 -and $reply[1] -eq 0)
            $client.Close()
            if ($ok) { return $true }
        }
        catch {
            if ($client) { try { $client.Close() } catch {} }
        }
        Start-Sleep -Milliseconds 1200
    }
    return $false
}

function Get-V2RayStatus {
    if (($Script:V2RayProcess) -and (-not $Script:V2RayProcess.HasExited)) {
        return $true
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
    Set-ProxyRegistry -Enable 1 -Server "socks=127.0.0.1:10808"
    $Script:ProxyActive = $true
    Write-Status "System proxy enabled: socks=127.0.0.1:10808" "OK"
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

