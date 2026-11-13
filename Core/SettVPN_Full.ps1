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
$Script:TunStateFile = Join-Path $Script:TempDir "tun-active.json"
$Script:TunReadyFile = Join-Path $Script:TempDir "tun-ready.txt"
$Script:AppLog = Join-Path $Script:TempDir "settvpn.log"
$Script:KillSwitchBackup = Join-Path $Script:TempDir "killswitch-backup.json"
$Script:SplitFile = Join-Path $Script:TempDir "split-direct.txt"
$Script:GeoIpFile = Join-Path $Script:TempDir "geoip.bin"
$Script:GeoIpData = $null
$Script:SocksPort = 10808
$Script:HttpPort = 10809
$Script:ApiPort = 10085
$Script:ScanPortBase = 20000
$Script:ExitIp = ""
$Script:KillSwitch = $false
$Script:FuncSource = $null
$Script:AbcConfigsUrl = "https://raw.githubusercontent.com/FreeFolksOn/abc-configs-free-vpn-proxy-list/main/README.md"
$Script:SubConfigsUrl = "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"
$Script:Sub2ConfigsUrl = "https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list.txt"

# Codigo do kill switch. Roda SOMENTE no supervisor elevado (e no restaurador avulso):
# fica em string para ser injetado por -EncodedCommand, nunca como .ps1 gravavel.
# Entrada por variaveis de ambiente (SETTVPN_*) para nao depender de escaping.
$Script:KillSwitchFuncs = @'
function Restore-SettVpnFirewall {
    $backup = $env:SETTVPN_KS_BACKUP
    $restored = $false
    if ($backup -and (Test-Path -LiteralPath $backup)) {
        try {
            $b = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
            # Primeiro devolve a politica de saida: janela sem bloqueio e melhor que
            # janela sem as regras de permissao.
            foreach ($p in @($b.Profiles)) {
                Set-NetFirewallProfile -Profile $p.Name -DefaultOutboundAction $p.Action -ErrorAction Stop
            }
            $restored = $true
        }
        catch { }
    }
    else { $restored = $true }

    if ($restored) {
        try { Remove-NetFirewallRule -Group 'SettVPN KillSwitch' -ErrorAction Stop } catch { }
        if ($backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
    return $restored
}

function Enable-SettVpnKillSwitch {
    $backup = $env:SETTVPN_KS_BACKUP
    $xray = $env:SETTVPN_XRAY
    if (-not $backup -or -not $xray) { return $false }
    if (Test-Path -LiteralPath $backup) { return $false }

    $profiles = @()
    foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
        $profiles += @{ Name = [string]$p.Name; Action = [string]$p.DefaultOutboundAction }
    }
    $json = @{ Profiles = $profiles } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($backup, $json, (New-Object System.Text.UTF8Encoding($false)))

    try {
        $group = 'SettVPN KillSwitch'
        try { Remove-NetFirewallRule -Group $group -ErrorAction Stop } catch { }
        # xray precisa discar para o servidor mesmo com a saida bloqueada.
        New-NetFirewallRule -DisplayName 'SettVPN KS: xray' -Group $group -Direction Outbound -Action Allow -Program $xray -Profile Any -ErrorAction Stop | Out-Null
        # Proxy local e API de estatisticas.
        New-NetFirewallRule -DisplayName 'SettVPN KS: loopback' -Group $group -Direction Outbound -Action Allow -RemoteAddress 127.0.0.1,::1 -Profile Any -ErrorAction Stop | Out-Null
        # Pacotes que entram no adaptador TUN vem de processos sem regra propria: sem
        # esta permissao o modo TUN morre junto com o firewall.
        $aliases = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match 'Wintun' } | ForEach-Object { $_.Name })
        foreach ($alias in $aliases) {
            New-NetFirewallRule -DisplayName "SettVPN KS: tun $alias" -Group $group -Direction Outbound -Action Allow -InterfaceAlias $alias -Profile Any -ErrorAction Stop | Out-Null
        }
        foreach ($p in $profiles) {
            Set-NetFirewallProfile -Profile $p.Name -DefaultOutboundAction Block -ErrorAction Stop
        }
        return $true
    }
    catch {
        [void](Restore-SettVpnFirewall)
        return $false
    }
}
'@


# ============================================================
# V2RAY - extraido pelo launcher (SettVPN.exe) para %TEMP%\SettVPN\v2ray.exe
# ============================================================

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-AppLog {
    param([string]$Message, [string]$Type = "INFO")
    try {
        Add-Content -Path $Script:AppLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Type] $Message" -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

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
    Write-AppLog -Message $Message -Type $Type
}

function Get-ScriptPort {
    param([string]$Name, [int]$Default)
    $v = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($v -and [int]$v -gt 0) { return [int]$v }
    return $Default
}

function Get-FreePort {
    param([int]$Start = 10808, [int[]]$Exclude = @())

    for ($p = $Start; $p -lt ($Start + 200); $p++) {
        if ($Exclude -contains $p) { continue }
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
            $listener.Start()
            return $p
        }
        catch { }
        finally { if ($listener) { try { $listener.Stop() } catch { } } }
    }
    return $Start
}

function Test-LocalPort {
    param([int]$Port = 0, [int]$TimeoutMs = 700)
    if ($Port -le 0) { $Port = Get-ScriptPort 'HttpPort' 10809 }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($ar)
        return $true
    }
    catch { return $false }
    finally { if ($client) { try { $client.Close() } catch { } } }
}

function Restore-OrphanTun {
    if (-not (Test-Path $Script:TunStateFile)) { return }

    # Execucao anterior caiu com TUN ativo: o supervisor elevado pode estar orfao.
    try {
        $stopFile = Join-Path $Script:TempDir "tun-stop.txt"
        New-Item -Path $stopFile -ItemType File -Force | Out-Null
        Start-Sleep -Seconds 2
        Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    }
    catch { }
    Remove-Item $Script:TunStateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $Script:TunReadyFile -Force -ErrorAction SilentlyContinue
    Write-Status "Previous TUN session stopped" "WARN"
}

function Test-KillSwitchActive {
    return [bool]($Script:KillSwitchBackup -and (Test-Path $Script:KillSwitchBackup))
}

function Restore-OrphanKillSwitch {
    # Firewall com saida bloqueada sobrou de uma execucao que morreu. Sem isso o
    # usuario fica sem internet ate restaurar o perfil na mao.
    if (-not (Test-Path $Script:KillSwitchBackup)) { return }

    $code = $Script:KillSwitchFuncs + "`n[void](Restore-SettVpnFirewall)"
    $env:SETTVPN_KS_BACKUP = $Script:KillSwitchBackup
    try {
        if (Test-IsAdmin) {
            & ([scriptblock]::Create($code)) | Out-Null
        }
        else {
            Write-Status "Restoring firewall (kill switch) from the previous run..." "WARN"
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
            $p = Start-Process powershell -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
            [void]$p.WaitForExit(20000)
        }
    }
    catch {
        Write-Status "FAILED to restore the firewall: accept UAC or restore the outbound profile in Windows Defender Firewall" "ERROR"
    }
    finally {
        Remove-Item Env:\SETTVPN_KS_BACKUP -ErrorAction SilentlyContinue
    }

    if (Test-Path $Script:KillSwitchBackup) {
        Write-Status "Firewall STILL blocking (kill switch) - restore the outbound profile manually" "ERROR"
    }
    else {
        Write-Status "Firewall restored" "OK"
    }
}

function Stop-OrphanXray {
    try {
        Get-Process -Name "v2ray" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $Script:V2RayExe } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Initialize-Environment {
    if (-not (Test-Path $Script:TempDir)) {
        New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
        Write-Status "Created temp directory: $Script:TempDir" "OK"
    }

    if (Test-Path $Script:AppLog) {
        try {
            if ((Get-Item $Script:AppLog).Length -gt 1MB) {
                Move-Item $Script:AppLog "$($Script:AppLog).old" -Force
            }
        }
        catch { }
    }

    Restore-OrphanTun
    Restore-OrphanKillSwitch
    Stop-OrphanXray

    $Script:SocksPort = Get-FreePort -Start 10808
    $Script:HttpPort = Get-FreePort -Start ($Script:SocksPort + 1) -Exclude @($Script:SocksPort)
    $Script:ApiPort = Get-FreePort -Start 10085 -Exclude @($Script:SocksPort, $Script:HttpPort)
    Write-Status "Proxy local: SOCKS5 127.0.0.1:$($Script:SocksPort) | HTTP 127.0.0.1:$($Script:HttpPort)" "INFO"

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

function ConvertTo-PsLiteral {
    param([string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-HostValue {
    param([string]$HostValue)
    if ($HostValue -match '^\[(.+)\]$') { return $matches[1] }
    return $HostValue
}

function ConvertFrom-Base64Text {
    param([string]$Text)

    if (-not $Text) { return $null }
    $t = $Text.Trim().Replace('-', '+').Replace('_', '/')
    while ($t.Length % 4 -ne 0) { $t += '=' }
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t)) }
    catch { return $null }
}

function Split-HostPort {
    param([string]$Endpoint)

    if ($Endpoint -match '^\[([^\]]+)\]:(\d+)$') { return @{ Host = $matches[1]; Port = [int]$matches[2] } }
    if ($Endpoint -match '^(.+):(\d+)$') { return @{ Host = $matches[1]; Port = [int]$matches[2] } }
    return $null
}

function Get-PropOr {
    param($Object, [string]$Name, $Default = $null)

    # ConvertFrom-Json + StrictMode: campo opcional ausente faz acesso direto estourar.
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-ConfigKey {
    param([hashtable]$Config)

    # Indexer: hashtables de protocolos diferentes tem chaves diferentes (SS nao tem UUID).
    $vals = foreach ($name in @('Protocol', 'Host', 'Port', 'UUID', 'Password', 'Method', 'Network', 'Params', 'WsPath', 'WsHost', 'TLS', 'SNI')) {
        [string]$Config[$name]
    }
    return ($vals -join '|')
}

function Get-HashValue {
    param([hashtable]$Table, [string]$Name, $Default = $null)

    # StrictMode: ler chave ausente de hashtable estoura (campo opcional de vmess).
    if ($Table -and $Table.ContainsKey($Name) -and $null -ne $Table[$Name]) { return $Table[$Name] }
    return $Default
}

function Parse-VlessConfig {
    param([string]$Uri)
    
    try {
        if ($Uri -match '^vless://([^@]+)@(\[[0-9A-Fa-f:.]+\]|[^:/?#]+):(\d+)(?:\?(.*?))?(?:#(.*))?$') {
            $uuid = $matches[1]
            $srvHost = ConvertTo-HostValue $matches[2]
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
        if ($Uri -notmatch '^ss://(.+)$') { return $null }
        $body = $matches[1]

        $name = ""
        if ($body -match '^(.*?)#(.*)$') {
            $body = $matches[1]
            $name = Unescape-Safe $matches[2]
        }
        if ($body -match '^(.*?)\?(.*)$') { $body = $matches[1] }

        $method = ""
        $password = ""
        $endpoint = ""

        # SIP002: ss://base64(method:pass)@host:port ou ss://method:pass@host:port
        if ($body -match '^([^@]+)@(.+)$') {
            $credRaw = $matches[1]
            $endpoint = $matches[2]
            $cred = ConvertFrom-Base64Text $credRaw
            if (-not $cred) { $cred = Unescape-Safe $credRaw }
            if ($cred -match '^([^:]+):(.+)$') {
                $method = $matches[1]
                $password = $matches[2]
            }
        }
        else {
            # Formato legado: ss://base64(method:pass@host:port)
            $decoded = ConvertFrom-Base64Text $body
            if ($decoded -and $decoded -match '^([^:]+):(.+)@(.+)$') {
                $method = $matches[1]
                $password = $matches[2]
                $endpoint = $matches[3]
            }
        }

        if (-not $method -or -not $endpoint) { return $null }
        $hp = Split-HostPort $endpoint
        if (-not $hp) { return $null }
        if ($hp.Port -le 0 -or $hp.Port -gt 65535) { return $null }
        if (-not $name) { $name = $hp.Host }

        return @{
            Protocol = "shadowsocks"
            Method = $method
            Password = $password
            Host = $hp.Host
            Port = [int]$hp.Port
            Params = ""
            Name = $name
            Raw = $Uri
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
        if ($Uri -match '^trojan://([^@]+)@(\[[0-9A-Fa-f:.]+\]|[^:/?#]+):(\d+)(?:\?(.*?))?(?:#(.*))?$') {
            $password = $matches[1]
            $srvHost = ConvertTo-HostValue $matches[2]
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
            $decoded = ConvertFrom-Base64Text $matches[1]
            if (-not $decoded) { return $null }
            $json = $decoded | ConvertFrom-Json

            $id = [string](Get-PropOr $json 'id' '')
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$guid)) {
                Write-Status "Skipping VMess config with non-UUID id: $id" "WARN"
                return $null
            }

            $srvHost = ConvertTo-HostValue ([string](Get-PropOr $json 'add' ''))
            $port = [int](Get-PropOr $json 'port' 0)
            if (-not $srvHost -or $port -le 0 -or $port -gt 65535) { return $null }

            return @{
                Protocol = "vmess"
                Host = $srvHost
                Port = $port
                UUID = $id
                AlterID = [int](Get-PropOr $json 'aid' 0)
                Network = [string](Get-PropOr $json 'net' 'tcp')
                Type = [string](Get-PropOr $json 'type' 'none')
                Security = [string](Get-PropOr $json 'scy' 'auto')
                TLS = [string](Get-PropOr $json 'tls' '')
                SNI = [string](Get-PropOr $json 'sni' '')
                WsHost = [string](Get-PropOr $json 'host' '')
                WsPath = [string](Get-PropOr $json 'path' '/')
                Alpn = [string](Get-PropOr $json 'alpn' '')
                Fingerprint = [string](Get-PropOr $json 'fp' '')
                Name = [string](Get-PropOr $json 'ps' $srvHost)
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
    # Bandeiras/emoji das listas nao tem glifo em toda fonte e aparecem como quadrado.
    $Name = $Name -replace '[\uD800-\uDFFF\uFE0F\u2600-\u27BF\u2B00-\u2BFF]', ''
    # As listas metem host e protocolo no nome: "DE[www.v2nodes.com] vless-DE-1 #6".
    $clean = ($Name -replace '\[[^\]]*\]', '' -replace '\s*@[A-Za-z0-9_.-]+$', '' -replace '\b(vless|vmess|trojan|shadowsocks)[-_ ]', '' -replace '\s+', ' ').Trim().TrimEnd('|', '-', '_', ' ')
    # Nome so com protocolo/host: usa o host em vez de devolver o nome cru.
    if (-not $clean) {
        $hostMatch = [regex]::Match($Name, '\[([^\]]+)\]')
        $clean = if ($hostMatch.Success) { $hostMatch.Groups[1].Value } else { $Name.Trim() }
    }    if ($clean) { $Name = $clean }
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

    # Dedup: remove espelhos reais (mesma credencial/transporte/host/porta).
    # Nao use so host:porta: nos nos CDN (Cloudflare) varios UUIDs diferem e todos funcionam.
    $seen = @{}
    $unique = @()
    foreach ($cfg in $configs) {
        $key = Get-ConfigKey -Config $cfg
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $cfg
        }
    }
    $dupes = $configs.Count - $unique.Count
    if ($dupes -gt 0) { Write-Status "Removed $dupes duplicate configs (mirrors)" "INFO" }
    $configs = $unique

    if ($configs.Count -gt 400) {
        $configs = @($configs[0..399])
    }
    Write-Status "Found $($configs.Count) configs (after filtering)" "INFO"
    return $configs
}

function Get-ServerPingMs {
    param($Config)
    # RealPing = HTTP 204 medido dentro do tunel (o que o usuario sente). Ping =
    # TCP ate o servidor e mente: CDN responde rapido e o caminho do proxy esta morto.
    if ($Config.ContainsKey('RealPing')) {
        $rp = [int]$Config['RealPing']
        if ($rp -gt 0 -and $rp -lt 9999) { return $rp }
    }
    return [int]$Config['Ping']
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
    param([array]$Configs, [int]$BatchSize = 64)

    $n = $Configs.Count
    Write-Status "Testing connectivity for $n configs..." "INFO"

    $timeoutMs = 3000

    # Conecta em lotes: centenas de SYNs simultaneos saturam NAT/portas efemeras.
    for ($offset = 0; $offset -lt $n; $offset += $BatchSize) {
        $end = [Math]::Min($offset + $BatchSize, $n) - 1
        $batch = @($Configs[$offset..$end])
        $bn = $batch.Count

        $tcpArr = [object[]]::new($bn)
        $swArr  = [object[]]::new($bn)
        $arArr  = [object[]]::new($bn)
        $done   = [bool[]]::new($bn)

        for ($i = 0; $i -lt $bn; $i++) {
            $cfg = $batch[$i]
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
        $remaining = $bn
        while ($remaining -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            for ($i = 0; $i -lt $bn; $i++) {
                if ($done[$i] -or $null -eq $arArr[$i]) { continue }
                if ($arArr[$i].IsCompleted) {
                    $cfg = $batch[$i]
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
        for ($i = 0; $i -lt $bn; $i++) {
            if (-not $done[$i]) {
                $batch[$i].Ping = 9999
                if ($null -ne $tcpArr[$i]) { try { $tcpArr[$i].Close() } catch {} }
            }
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
        if (-not $sni) { $sni = Get-ParamValue $P "host" }
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

    if ($network -eq "tcp") {
        $headerType = Get-ParamValue $P "headerType"
        if ($headerType -eq "http") {
            $tcp = @{ header = @{ type = "http" } }
            $req = @{}
            $path = Get-ParamValue $P "path"
            if ($path) { $req.path = @($path) }
            $hdr = Get-ParamValue $P "host"
            if ($hdr) { $req.headers = @{ Host = @($hdr) } }
            if ($req.Count -gt 0) { $tcp.header.request = $req }
            $stream.tcpSettings = $tcp
        }
    }
    elseif ($network -eq "ws") {
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

function Format-Bytes {
    param([int64]$Bytes = 0)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $v = [double]$Bytes
    foreach ($u in @('KB', 'MB', 'GB', 'TB')) {
        $v = $v / 1024
        if ($v -lt 1024) { return ('{0:0.0} {1}' -f $v, $u) }
    }
    return ('{0:0.0} PB' -f $v)
}

function Get-SplitDirectLines {
    $file = [string](Get-Variable -Name SplitFile -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not $file -or -not (Test-Path $file)) { return @() }
    try {
        return @(Get-Content -LiteralPath $file -ErrorAction Stop | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    }
    catch { return @() }
}

function New-SplitRoutingRules {
    param([string[]]$Lines = @(), [switch]$NoLocal)

    $domains = New-Object 'System.Collections.Generic.List[string]'
    $ips = New-Object 'System.Collections.Generic.List[string]'

    # Faixas locais nunca podem ir para o proxy em modo TUN (LAN, link-local, loopback).
    # Sem geoip.dat embarcado: CIDRs explicitos.
    if (-not $NoLocal) {
        foreach ($c in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '127.0.0.0/8', '100.64.0.0/10', 'fc00::/7', 'fe80::/10', '::1/128')) {
            $ips.Add($c)
        }
    }

    foreach ($raw in @($Lines)) {
        $line = ([string]$raw).Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^(geoip|ext|geosite|domain|full|regexp|keyword):') {
            if ($line.StartsWith('geoip:') -or $line.StartsWith('ext:')) { $ips.Add($line) } else { $domains.Add($line) }
            continue
        }
        $addr = $line -replace '/.*$', ''
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($addr, [ref]$parsed)) {
            if ($line.Contains('/')) { $ips.Add($line) } else { $ips.Add($addr) }
        }
        else { $domains.Add($line.ToLowerInvariant()) }
    }

    $rules = @()
    # Condicoes no MESMO rule sao AND no Xray: dominio e IP precisam de rules separadas.
    if ($domains.Count -gt 0) { $rules += @{ type = 'field'; domain = @($domains); outboundTag = 'direct' } }
    if ($ips.Count -gt 0) { $rules += @{ type = 'field'; ip = @($ips); outboundTag = 'direct' } }
    return $rules
}

function Get-TrafficStats {
    param([int]$ApiPort = 0, [string]$Exe = "")

    if ($ApiPort -le 0) { $ApiPort = Get-ScriptPort 'ApiPort' 10085 }
    if (-not $Exe) { $Exe = [string](Get-Variable -Name V2RayExe -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    if (-not $Exe -or -not (Test-Path $Exe)) { return $null }

    try {
        $out = & $Exe api statsquery "--server=127.0.0.1:$ApiPort" 2>$null
        $text = ([string]($out | Out-String)).Trim()
        if (-not $text) { return $null }
        $obj = $text | ConvertFrom-Json
        if (-not $obj -or -not ($obj.PSObject.Properties.Name -contains 'stat')) { return $null }

        $up = [int64]0
        $down = [int64]0
        foreach ($s in @($obj.stat)) {
            if (-not $s.value) { continue }
            # A propria consulta de stats conta no inbound api - ignorar.
            if ($s.name -like 'inbound>>>api>>>*') { continue }
            if ($s.name -like '*>>>traffic>>>uplink') { $up += [int64]$s.value }
            elseif ($s.name -like '*>>>traffic>>>downlink') { $down += [int64]$s.value }
        }
        return @{ Up = $up; Down = $down }
    }
    catch { return $null }
}

function Generate-V2RayConfig {
    param([hashtable]$Config, [bool]$Tun = $false, [int]$SocksPort = 0, [int]$HttpPort = 0, [string]$ConfigPath = "", [string]$LogPath = "", [int]$ApiPort = 0)

    if ($SocksPort -le 0) { $SocksPort = Get-ScriptPort 'SocksPort' 10808 }
    if ($HttpPort -le 0) { $HttpPort = Get-ScriptPort 'HttpPort' 10809 }

    if (-not $ConfigPath) { $ConfigPath = $Script:ConfigJson }
    if (-not $LogPath) { $LogPath = $Script:XrayLog }

    $configObj = @{
        log = @{
            loglevel = "warning"
            error    = $LogPath
        }
        inbounds = @(
            @{
                listen   = "127.0.0.1"
                port = $SocksPort
                protocol = "socks"
                tag      = "socks-in"
                settings = @{
                    auth = "noauth"
                    udp = $true
                }
            },
            @{
                listen   = "127.0.0.1"
                port = $HttpPort
                protocol = "http"
                tag      = "http-in"
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

    $routingRules = @()

    # Stats do xray: StatsService + inbound dokodemo-door na tag "api". O rule
    # inboundTag->api e obrigatorio, sem ele o xray nem abre a porta.
    if ($ApiPort -gt 0) {
        $configObj.api = @{ tag = "api"; services = @("StatsService") }
        $configObj.stats = @{}
        $configObj.policy = @{ system = @{ statsInboundUplink = $true; statsInboundDownlink = $true } }
        $configObj.inbounds += @{
            listen   = "127.0.0.1"
            port     = $ApiPort
            protocol = "dokodemo-door"
            settings = @{ address = "127.0.0.1" }
            tag      = "api"
        }
        $routingRules += @{ type = "field"; inboundTag = @("api"); outboundTag = "api" }
    }

    # Split tunneling: dominios/IPs listados vao direto. Soh faz sentido em TUN
    # (no modo proxy quem escolhe o destino e o app). Inclui as faixas locais.
    if ($Tun) {
        foreach ($r in @(New-SplitRoutingRules -Lines @(Get-SplitDirectLines))) { $routingRules += $r }
    }

    $paramHash = ConvertTo-ParamHashtable -Params ([string](Get-HashValue $Config 'Params' ''))

    if ((Get-ParamValue $paramHash "type" "tcp") -eq "xhttp") {
        Write-Status "Skipping config (transport xhttp not supported by this v2ray build)" "WARN"
        return $false
    }

    if ($Config.Protocol -eq "vless") {
        $stream = New-StreamSettings -P $paramHash

        $user = @{
            id = $Config.UUID
            encryption = (Get-ParamValue $paramHash "encryption" "none")
        }
        $flow = Get-ParamValue $paramHash "flow"
        if ($flow) { $user.flow = $flow }

        $vless = @{
            vnext = @(
                @{
                    address = $Config.Host
                    port = $Config.Port
                    users = @($user)
                }
            )
        }
        $packetEncoding = Get-ParamValue $paramHash "packetEncoding"
        if ($packetEncoding) { $vless.packetEncoding = $packetEncoding }

        $outbound = @{
            protocol = "vless"
            settings = $vless
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
        if ($stream.security -eq "tls") {
            if (-not $stream.ContainsKey('tlsSettings')) { $stream.tlsSettings = @{} }
            if (-not $stream.tlsSettings.ContainsKey('serverName')) {
                $sni = Get-ParamValue $paramHash "sni" ([string]$Config.Host)
                if ($sni) { $stream.tlsSettings.serverName = $sni }
            }
        }
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
        $net = [string](Get-HashValue $Config 'Network' 'tcp')
        if (-not $net) { $net = "tcp" }
        if ($net -notin @("tcp", "ws")) {
            Write-Status "Skipping unsupported VMess transport: $net" "WARN"
            return $false
        }

        $stream = @{ network = $net }
        $tls = [string](Get-HashValue $Config 'TLS' '')
        if ($tls -eq "tls") {
            $tlsObj = @{}
            $sni = [string](Get-HashValue $Config 'SNI' '')
            if (-not $sni) { $sni = [string](Get-HashValue $Config 'WsHost' '') }
            if ($sni) { $tlsObj.serverName = $sni }
            $alpn = [string](Get-HashValue $Config 'Alpn' '')
            if ($alpn) { $tlsObj.alpn = @($alpn -split ',') }
            $fp = [string](Get-HashValue $Config 'Fingerprint' '')
            if ($fp) { $tlsObj.fingerprint = $fp }
            $stream.security = "tls"
            $stream.tlsSettings = $tlsObj
        }
        if ($net -eq "ws") {
            $ws = @{}
            $path = [string](Get-HashValue $Config 'WsPath' '')
            if ($path) { $ws.path = $path }
            $wsHost = [string](Get-HashValue $Config 'WsHost' '')
            if ($wsHost) { $ws.headers = @{ Host = $wsHost } }
            $stream.wsSettings = $ws
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
                                alterId = [int](Get-HashValue $Config 'AlterID' 0)
                                security = (Get-HashValue $Config 'Security' 'auto')
                            }
                        )
                    }
                )
            }
            streamSettings = $stream
        }
        $configObj.outbounds += $outbound
    }

    if ($Tun) {
        $configObj.outbounds += @{ protocol = "freedom"; tag = "direct" }
    }
    if ($routingRules.Count -gt 0) {
        $configObj.routing = @{ rules = @($routingRules) }
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

    # VMess guarda o transport em Network (nao em Params); tcp e ws sao suportados.
    if ($Config['Protocol'] -eq 'vmess') {
        $net = [string]$Config['Network']
        if ($net -and $net -notin @('tcp', 'ws')) { return $false }
    }

    return $true
}

function Get-FuncSource {
    # Reconstroi o codigo-fonte das funcoes (p/ redefinir em runspaces paralelos).
    $cached = Get-Variable -Name FuncSource -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($cached) { return $cached }

    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script:ScriptFile, [ref]$tokens, [ref]$errs)
    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $src = (($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n")
    Set-Variable -Name FuncSource -Scope Script -Value $src
    return $src
}

function Measure-TunnelHttpMs {
    param([int]$SocksPort = 0, [int]$TimeoutMs = 4000)

    # Latencia sentida pelo usuario: HTTP 204 atraves do SOCKS do xray.
    if ($SocksPort -le 0) { $SocksPort = Get-ScriptPort 'SocksPort' 10808 }
    $client = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $ar = $client.BeginConnect("127.0.0.1", $SocksPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return 9999 }
        $client.EndConnect($ar)
        $stream = $client.GetStream()

        $hello = [byte[]](5, 1, 0)
        $stream.Write($hello, 0, 3)
        $resp = New-Object byte[] 2
        if ($stream.Read($resp, 0, 2) -lt 2 -or $resp[1] -ne 0) { return 9999 }

        $domain = "cp.cloudflare.com"
        $db = [System.Text.Encoding]::ASCII.GetBytes($domain)
        $portBytes = [BitConverter]::GetBytes([UInt16]80)
        [Array]::Reverse($portBytes)
        $req = New-Object byte[] (7 + $db.Length)
        $req[0] = 5; $req[1] = 1; $req[2] = 0; $req[3] = 3; $req[4] = [byte]$db.Length
        [Array]::Copy($db, 0, $req, 5, $db.Length)
        $req[5 + $db.Length] = $portBytes[0]
        $req[6 + $db.Length] = $portBytes[1]
        $stream.Write($req, 0, $req.Length)
        $reply = New-Object byte[] 256
        if ($stream.Read($reply, 0, 256) -lt 2 -or $reply[1] -ne 0) { return 9999 }

        $http = "GET /generate_204 HTTP/1.1`r`nHost: $domain`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($http)
        $stream.Write($hb, 0, $hb.Length)
        $buf = New-Object byte[] 64
        if ($stream.Read($buf, 0, 64) -le 0) { return 9999 }
        $sw.Stop()
        return [int]$sw.ElapsedMilliseconds
    }
    catch { return 9999 }
    finally { if ($client) { try { $client.Close() } catch { } } }
}

function Get-ExitIp {
    param([int]$HttpPort = 0, [int]$TimeoutMs = 5000)

    if ($HttpPort -le 0) { $HttpPort = Get-ScriptPort 'HttpPort' 10809 }
    $proxy = "http://127.0.0.1:$HttpPort"
    $timeoutSec = [int][Math]::Max(1, [Math]::Ceiling($TimeoutMs / 1000))

    try {
        $r = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -Proxy $proxy -TimeoutSec $timeoutSec -ErrorAction Stop
        if ($r.ip) {
            if ($r.country) { return "$($r.ip) ($($r.country))" }
            return [string]$r.ip
        }
    }
    catch { }

    try {
        $ip = (Invoke-WebRequest -Uri 'https://api.ipify.org' -Proxy $proxy -TimeoutSec $timeoutSec -UseBasicParsing -ErrorAction Stop).Content.Trim()
        if ($ip) { return $ip }
    }
    catch { }

    return ""
}

function Test-ServerStable {
    param([hashtable]$Config, [int]$SocksPort = 0, [int]$HttpPort = 0, [string]$ConfigPath = "", [string]$LogPath = "", [int]$StabilitySeconds = 6)

    if ($SocksPort -le 0) { $SocksPort = Get-ScriptPort 'SocksPort' 10808 }
    if ($HttpPort -le 0) { $HttpPort = Get-ScriptPort 'HttpPort' 10809 }
    $Script:LastRealPing = 0

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
        # Sem redirect: pipe nao drenado enche e trava o xray. O log vai pro arquivo.

        $proc = [System.Diagnostics.Process]::Start($psi)

        # 1) prontidao: espera o tunel responder (poll ate ~3s, sem sleep cego)
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
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
        if (-not (Test-V2RayUdp -TimeoutMs 2500 -SocksPort $SocksPort)) { return $false }

        # 4) latencia real: HTTP 204 atraves do tunel. O CONNECT do socks responde
        # antes de discar (0 ms para alvo morto), o ping do banco e so TCP ate o
        # servidor; so o dado voltando mede o que o usuario sente.
        $pingMs = Measure-TunnelHttpMs -SocksPort $SocksPort -TimeoutMs 4000
        $Script:LastRealPing = $pingMs
        return ($pingMs -lt 9999)
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

function Get-SpreadSample {
    param([array]$Items, [int]$Max = 12)

    # Amostra espalhada: os servidores de menor ping costumam ser CDN com caminho
    # morto; pegar so o topo fazia o teste/conexao falhar sempre.
    if (-not $Items -or $Items.Count -le $Max) { return @($Items) }
    $step = [Math]::Max(1, [int][Math]::Floor($Items.Count / $Max))
    $picked = @()
    for ($i = 0; $i -lt $Items.Count -and $picked.Count -lt $Max; $i += $step) { $picked += $Items[$i] }
    return $picked
}

function Scan-StableServers {
    param([array]$Configs, [int]$MaxToTest = 40, [int]$StabilitySeconds = 2, [int]$MinStable = 10,
          [int]$Concurrency = [Math]::Min(12, [Math]::Max(4, [Environment]::ProcessorCount)))

    $stable = @()
    $tested = 0
    if (-not $Configs -or $Configs.Count -eq 0) { return $stable }
    $Configs = @(Get-SpreadSample -Items $Configs -Max $MaxToTest)
    $total = $Configs.Count
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
    $scanBase = Get-ScriptPort 'ScanPortBase' 20000
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($c in $Configs) { $queue.Enqueue($c) }
    $running = New-Object 'System.Collections.Generic.List[object]'
    $freePorts = New-Object 'System.Collections.Generic.Queue[int]'
    for ($p = 0; $p -lt $Concurrency; $p++) { $freePorts.Enqueue($scanBase + ($p * 10)) }
    $results = [hashtable]::Synchronized(@{})
    $realPings = [hashtable]::Synchronized(@{})

    # Pipeline: slot livre pega o proximo servidor na hora. Esperar o lote inteiro
    # deixava o scan refem do servidor mais lento (timeout de 10s por dead path).
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Concurrency -and $queue.Count -gt 0 -and ($MinStable -le 0 -or $stable.Count -lt $MinStable)) {
            $cfg = $queue.Dequeue()
            $socks = $freePorts.Dequeue()
            $http = $socks + 1

            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $rs.SessionStateProxy.SetVariable('scanFuncSource', $funcSource)
            $rs.SessionStateProxy.SetVariable('scanCfg', $cfg)
            $rs.SessionStateProxy.SetVariable('scanSocks', $socks)
            $rs.SessionStateProxy.SetVariable('scanHttp', $http)
            $rs.SessionStateProxy.SetVariable('scanStab', $StabilitySeconds)
            $rs.SessionStateProxy.SetVariable('scanResults', $results)
            $rs.SessionStateProxy.SetVariable('scanReal', $realPings)
            $rs.SessionStateProxy.SetVariable('scanSlot', $socks)
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
$scanReal[$scanSlot] = $Script:LastRealPing
'@)
            $job = [pscustomobject]@{
                Ps     = $ps
                Rs     = $rs
                Handle = $ps.BeginInvoke()
                Cfg    = $cfg
                Socks  = $socks
            }
            $running.Add($job)
        }

        # Espera o primeiro terminar (qualquer um), coleta e libera o slot.
        $fin = $null
        while (-not $fin) {
            foreach ($job in $running) {
                if ($job.Handle.IsCompleted) { $fin = $job; break }
            }
            if (-not $fin) { Start-Sleep -Milliseconds 50 }
        }
        $running.Remove($fin) | Out-Null
        try { $fin.Ps.EndInvoke($fin.Handle) } catch { }
        try { $fin.Rs.Dispose() } catch { }
        try { $fin.Ps.Dispose() } catch { }
        $freePorts.Enqueue($fin.Socks)

        $tested++
        if ($Sync) { $Sync.ScanTested = $tested; $Sync.Progress = [int](($tested / $total) * 100) }

        if ($results.ContainsKey($fin.Socks) -and $results[$fin.Socks]) {
            $real = 0
            if ($realPings.ContainsKey($fin.Socks)) { $real = [int]$realPings[$fin.Socks] }
            $fin.Cfg.RealPing = $real
            $stable += $fin.Cfg
            if ($real -gt 0 -and $real -lt 9999) {
                Write-Status "Working (TCP+UDP, ${real}ms real): $(Get-ShortName $fin.Cfg.Name)" "OK"
            }
            else {
                Write-Status "Working (TCP+UDP): $(Get-ShortName $fin.Cfg.Name)" "OK"
            }
            if ($MinStable -gt 0 -and $stable.Count -ge $MinStable) {
                Write-Status "Stopping scan: $($stable.Count) working servers" "OK"
            }
        }
        else {
            Write-Status "Discarded: $(Get-ShortName $fin.Cfg.Name)" "WARN"
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
    if ($Sync) { $Sync.Progress = 100; $Sync.ScanDeadline = [DateTime]::Now }

    if ($stable.Count -gt 1) {
        $stable = @($stable | Sort-Object -Property @{ Expression = { if ($_.RealPing -and $_.RealPing -gt 0) { [int]$_.RealPing } else { 9999 } } })
    }
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
            'AL' = 'Albania'; 'BA' = 'Bosnia'; 'MK' = 'Macedonia do Norte'; 'ME' = 'Montenegro'; 'XK' = 'Kosovo';
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

function Initialize-GeoIpData {
    # Le os bytes para a variavel de script SEM devolver pelo pipeline: um byte[]
    # retornado por funcao e desenrolado em 3.6 milhoes de objetos e o
    # [BitConverter] precisa reconverte-los a cada consulta (minutos de CPU).
    if ($Script:GeoIpData) { return $true }

    $file = $Script:GeoIpFile
    if (-not $file -or -not (Test-Path $file)) { return $false }

    try { $Script:GeoIpData = [System.IO.File]::ReadAllBytes($file) } catch { return $false }
    # 10 bytes por registro: start(4) end(4) cc(2), little-endian. Gerado no build.
    if ($Script:GeoIpData.Length -lt 10 -or ($Script:GeoIpData.Length % 10) -ne 0) {
        $Script:GeoIpData = $null
        return $false
    }
    return $true
}

function Get-CountryCodeOffline {
    param([string]$Ip = "")

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$parsed)) { return "" }
    $b = $parsed.GetAddressBytes()
    if ($b.Length -ne 4) { return "" }

    if (-not (Initialize-GeoIpData)) { return "" }
    $data = $Script:GeoIpData

    $num = [System.BitConverter]::ToUInt32([byte[]]@($b[3], $b[2], $b[1], $b[0]), 0)
    $count = [int]($data.Length / 10)
    $lo = 0
    $hi = $count - 1
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        $off = $mid * 10
        $start = [System.BitConverter]::ToUInt32($data, $off)
        $end = [System.BitConverter]::ToUInt32($data, $off + 4)
        if ($num -lt $start) { $hi = $mid - 1 }
        elseif ($num -gt $end) { $lo = $mid + 1 }
        else {
            $cc = [System.Text.Encoding]::ASCII.GetString($data, $off + 8, 2)
            if ($cc -eq 'ZZ') { return "" }
            return $cc
        }
    }
    return ""
}

function Resolve-Countries {
    param([array]$Configs)

    if (-not $Configs -or $Configs.Count -eq 0) { return }

    # Garante chaves (strict mode). Nome do no e so fallback: mentira comum nas listas.
    $hosts = @{}
    foreach ($cfg in $Configs) {
        if (-not $cfg.ContainsKey('Country')) { $cfg['Country'] = '' }
        if (-not $cfg.ContainsKey('CountryCode')) { $cfg['CountryCode'] = '' }
        $cfg['NameCode'] = Get-CountryCodeFromName -Name ([string]$cfg.Name)
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

    # Cache em disco: IP -> codigo de pais. Expira em 60 dias (IP muda de dono).
    $cachePath = Join-Path $Script:TempDir 'geo-cache.json'
    $cache = @{}
    if (Test-Path $cachePath) {
        try {
            if (((Get-Date) - (Get-Item $cachePath).LastWriteTime).TotalDays -le 60) {
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
        if (-not $ip) { continue }

        # Nome primeiro: as listas livres rotulam o pais no nome, e o IP resolvido
        # pode ser CDN/anycast e apontar para outro pais (ex.: "us US-1" -> Canada).
        if ($cfg['NameCode']) {
            $cfg['CountryCode'] = $cfg['NameCode']
            $cfg['Country'] = Get-CountryNamePt -Code $cfg['NameCode']
            continue
        }

        # Cloudflare esconde a origem: sem pais no nome, mostra CDN.
        if (Test-CloudflareIp -IpString $ip) {
            $cfg['Country'] = 'Cloudflare CDN'
            continue
        }

        if ($cache.ContainsKey($ip)) {
            $cfg['CountryCode'] = $cache[$ip]
            $cfg['Country'] = Get-CountryNamePt -Code $cache[$ip]
        }
        else {
            # Base offline (DB-IP) primeiro: sem rede, sem rate limit.
            $offline = Get-CountryCodeOffline -Ip $ip
            if ($offline) {
                $cache[$ip] = $offline
                $cfg['CountryCode'] = $offline
                $cfg['Country'] = Get-CountryNamePt -Code $offline
            }
            else {
                [void]$missing.Add($ip)
            }
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

    # Fallback final: codigo do nome, e limpa a chave temporaria
    foreach ($cfg in $Configs) {
        if (-not $cfg['Country'] -and $cfg['NameCode']) {
            $cfg['CountryCode'] = $cfg['NameCode']
            $cfg['Country'] = Get-CountryNamePt -Code $cfg['NameCode']
        }
        $cfg.Remove('NameCode')
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-SupervisorScript {
    # Script que roda ELEVADO (via -EncodedCommand). Recebe tudo por ambiente.
    return $Script:KillSwitchFuncs + "`n" + @'
$ErrorActionPreference = 'Continue'
$xray = $env:SETTVPN_XRAY
$config = $env:SETTVPN_CFG
$stopFile = $env:SETTVPN_STOP
$readyFile = $env:SETTVPN_READY
$parentPid = [int]$env:SETTVPN_PARENT
$logPath = $env:SETTVPN_LOG

function Write-KsLog([string]$Message) {
    try { Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [KILLSWITCH] $Message" } catch { }
}

$p = Start-Process -FilePath $xray -ArgumentList "run -c `"$config`"" -PassThru -NoNewWindow
try {
    if ($env:SETTVPN_KS -eq '1') {
        # Espera o app confirmar o tunel (ou desistir): bloquear antes da hora
        # faz a conexao falhar sozinha.
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path $stopFile) -and -not $p.HasExited) {
            if (Test-Path $readyFile) { break }
            if (-not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
        }
        if ((Test-Path $readyFile) -and -not $p.HasExited) {
            if (Enable-SettVpnKillSwitch) {
                # Fail-open: se depois do bloqueio o tunel nao passar, restaura na hora.
                $ok = $false
                for ($i = 0; $i -lt 3 -and -not $ok; $i++) {
                    try {
                        $null = Invoke-WebRequest -Uri 'http://www.gstatic.com/generate_204' -Proxy "http://127.0.0.1:$($env:SETTVPN_HTTP)" -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
                        $ok = $true
                    }
                    catch { Start-Sleep -Milliseconds 700 }
                }
                if ($ok) { Write-KsLog 'ativo (bloqueado tudo exceto xray, loopback e a interface TUN)' }
                else {
                    [void](Restore-SettVpnFirewall)
                    Write-KsLog 'FALHOU: sem conectividade com as regras - firewall restaurado (fail-open)'
                }
            }
            else { Write-KsLog 'FALHOU ao aplicar as regras - firewall restaurado (fail-open)' }
        }
    }

    while (-not (Test-Path $stopFile) -and -not $p.HasExited) {
        if (-not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 300
    }
}
finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    # Sempre restaura: no auto-reconnect isso abre uma janela de poucos segundos
    # sem bloqueio. Manter o bloqueio entre supervisores exigiria um estado
    # "keep" (e um caminho de falha que deixasse o usuario offline para sempre).
    [void](Restore-SettVpnFirewall)
}
'@
}

function Start-V2Ray {
    param([hashtable]$Config, [int]$StabilitySeconds = 3, [bool]$Tun = $false)

    $Script:LastFailReason = ""
    $Script:ExitIp = ""

    # Stop existing process
    Stop-V2Ray

    $stopFile = Join-Path $Script:TempDir "tun-stop.txt"
    $readyFile = $Script:TunReadyFile
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    Remove-Item $readyFile -Force -ErrorAction SilentlyContinue

    # TUN no Windows exige o driver wintun.dll ao lado do v2ray.exe
    if ($Tun -and (-not $Script:WintunDll -or -not (Test-Path $Script:WintunDll))) {
        $Script:LastFailReason = "wintun.dll missing - TUN mode unavailable"
        Write-Status $Script:LastFailReason "ERROR"
        return $false
    }

    $ksRequested = [bool](Get-Variable -Name KillSwitch -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($ksRequested -and -not $Tun) { $ksRequested = $false }

    # Generate config
    if (-not (Generate-V2RayConfig -Config $Config -Tun $Tun -ApiPort (Get-ScriptPort 'ApiPort' 10085))) {
        $Script:LastFailReason = "Failed to generate xray config"
        return $false
    }

    # Start v2ray
    try {
        $Script:TunStopFile = $null
        Remove-Item $Script:TunStateFile -Force -ErrorAction SilentlyContinue

        if ($Tun) {
            # TUN exige admin (adaptador wintun). Sobe um supervisor elevado que
            # gerencia o xray e o kill switch; o resto do app segue sem privilegios.
            # Codigo vai por -EncodedCommand: nada de .ps1 gravavel pelo usuario rodando elevado.
            # Parametros por variavel de ambiente: sem escaping de caminho.
            $supervisorScript = New-SupervisorScript
            $envNames = @('SETTVPN_XRAY', 'SETTVPN_CFG', 'SETTVPN_STOP', 'SETTVPN_READY', 'SETTVPN_PARENT', 'SETTVPN_LOG', 'SETTVPN_KS', 'SETTVPN_KS_BACKUP', 'SETTVPN_HTTP')
            $env:SETTVPN_XRAY = $Script:V2RayExe
            $env:SETTVPN_CFG = $Script:ConfigJson
            $env:SETTVPN_STOP = $stopFile
            $env:SETTVPN_READY = $readyFile
            $env:SETTVPN_PARENT = [string]$PID
            $env:SETTVPN_LOG = $Script:AppLog
            $env:SETTVPN_KS = if ($ksRequested) { '1' } else { '0' }
            $env:SETTVPN_KS_BACKUP = $Script:KillSwitchBackup
            $env:SETTVPN_HTTP = [string]$Script:HttpPort
            try {
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($supervisorScript))
                $spArgs = @{
                    FilePath     = 'powershell'
                    PassThru     = $true
                    WindowStyle  = 'Hidden'
                    ArgumentList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
                }
                # Executavel ja elevado (manifest requireAdministrator): RunAs pediria
                # um segundo UAC sem motivo.
                if (-not (Test-IsAdmin)) { $spArgs.Verb = 'RunAs' }
                $supervisor = Start-Process @spArgs
            }
            finally {
                foreach ($n in $envNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
            }
            $Script:V2RayProcess = $supervisor
            $Script:TunStopFile = $stopFile

            # Marcador em disco: runspaces/processos futuros sabem que o xray pode estar elevado.
            $state = @{ StopFile = $stopFile; Started = (Get-Date).ToString("o") }
            [System.IO.File]::WriteAllText($Script:TunStateFile, ($state | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        }
        else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Script:V2RayExe
            $psi.Arguments = "run -c `"$Script:ConfigJson`""
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            # Sem redirect: pipe nao drenado enche e trava o xray. O log vai pro arquivo.

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
                $Script:LastFailReason = "TUN failed - traffic leaking. $reason"
                Write-Status $Script:LastFailReason "ERROR"
                Stop-V2Ray
                return $false
            }
            # Tunel confirmado: o supervisor elevado pode aplicar o kill switch.
            try { [System.IO.File]::WriteAllText($readyFile, (Get-Date).ToString("o")) } catch { }
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
                $Script:LastFailReason = "Server unstable (dropped): $(Get-ShortName $Config.Name)$(Get-FailReason)"
                Write-Status $Script:LastFailReason "WARN"
                Stop-V2Ray
                return $false
            }
        }

        if ($Script:V2RayProcess -and -not $Script:V2RayProcess.HasExited) {
            $socksPort = Get-ScriptPort 'SocksPort' 10808
            $httpPort = Get-ScriptPort 'HttpPort' 10809

            Write-Status "Connected to VPN: $(Get-ShortName $Config.Name)" "OK"
            Write-Status "Protocol: $($Config.Protocol) | Server: $($Config.Host):$($Config.Port) | Ping: $($Config.Ping)ms" "INFO"

            $Script:ExitIp = Get-ExitIp
            if ($Script:ExitIp) { Write-Status "Exit IP: $($Script:ExitIp)" "INFO" }

            Write-Host ""
            Write-Host "  =============================================" -ForegroundColor Cyan
            Write-Host "   Configure o proxy no navegador (SwitchyOmega):" -ForegroundColor Yellow
            Write-Host "     Tipo      : SOCKS5" -ForegroundColor White
            Write-Host "     Server    : 127.0.0.1" -ForegroundColor White
            Write-Host "     Porta     : $socksPort" -ForegroundColor White
            Write-Host "  --------------------------------------------" -ForegroundColor Cyan
            Write-Host "   Apps sem suporte a SOCKS5 (ex: Discord):" -ForegroundColor Yellow
            Write-Host "     Use o proxy HTTP 127.0.0.1:$httpPort" -ForegroundColor White
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
    $stopFile = Join-Path $Script:TempDir "tun-stop.txt"
    $tunWasActive = Test-Path $Script:TunStateFile
    $ksWasActive = Test-KillSwitchActive

    # xray elevado vive fora deste processo/runspace. O estado em disco e o sinal
    # que o supervisor observa; sem isso "Desconectar" mente e a rota TUN fica.
    if ($tunWasActive) {
        try { New-Item -Path $stopFile -ItemType File -Force | Out-Null } catch { }
    }
    Remove-Item $Script:TunReadyFile -Force -ErrorAction SilentlyContinue

    if ($Script:V2RayProcess) {
        $ownPid = $Script:V2RayProcess.Id
        try {
            if (-not $Script:V2RayProcess.HasExited) {
                # O supervisor ainda restaura o firewall antes de sair: matar cedo
                # deixaria a saida bloqueada.
                if ($tunWasActive) { [void]$Script:V2RayProcess.WaitForExit(10000) }
                if (-not $Script:V2RayProcess.HasExited) {
                    $Script:V2RayProcess.Kill()
                    [void]$Script:V2RayProcess.WaitForExit(3000)
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

    if ($tunWasActive) {
        # Espera a porta HTTP liberar: o xray elevado morre fora do nosso processo.
        $httpPort = Get-ScriptPort 'HttpPort' 10809
        for ($i = 0; $i -lt 20 -and (Test-LocalPort -Port $httpPort -TimeoutMs 200); $i++) {
            Start-Sleep -Milliseconds 250
        }
        Remove-Item $Script:TunStateFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
        $Script:TunStopFile = $null
        $Script:ExitIp = ""
    }

    # Supervisor morreu sem restaurar (ou app foi morto antes): UAC e a unica saida.
    if ($ksWasActive -and (Test-KillSwitchActive)) { Restore-OrphanKillSwitch }

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
        # So adaptador wintun (do xray). WireGuard do usuario nao vale como prova.
        $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wintun'
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
    param([int]$TimeoutMs = 2500, [int]$Attempts = 2, [int]$SocksPort = 0)

    if ($SocksPort -le 0) { $SocksPort = Get-ScriptPort 'SocksPort' 10808 }

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
    param([int]$TimeoutMs = 2500, [int]$SocksPort = 0)

    if ($SocksPort -le 0) { $SocksPort = Get-ScriptPort 'SocksPort' 10808 }

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
$Script:ProxyBackupOverride = $null
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
    param([int]$Enable, [string]$Server = "", [string]$Override)

    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $path -Name ProxyEnable -Value $Enable
    if ($Server) {
        Set-ItemProperty -Path $path -Name ProxyServer -Value $Server
    }
    if ($PSBoundParameters.ContainsKey('Override')) {
        Set-ItemProperty -Path $path -Name ProxyOverride -Value $Override
    }

    try {
        [WinInetNative]::InternetSetOption(0, 39, 0, 0) | Out-Null   # INTERNET_OPTION_SETTINGS_CHANGED
        [WinInetNative]::InternetSetOption(0, 37, 0, 0) | Out-Null   # INTERNET_OPTION_REFRESH
    }
    catch { }
}

function Save-ProxyBackup {
    param([int]$Enable, [string]$Server, [string]$Override)
    try {
        $obj = @{ Enable = $Enable; Server = [string]$Server; Override = [string]$Override }
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
            $enable = 0
            if ($null -ne (Get-PropOr $obj 'Enable')) { $enable = [int](Get-PropOr $obj 'Enable') }
            Set-ProxyRegistry -Enable $enable -Server ([string](Get-PropOr $obj 'Server' '')) -Override ([string](Get-PropOr $obj 'Override' ''))
            Write-Status "System proxy restored (previous run crashed with proxy active)" "WARN"
        }
    }
    catch { }
    Clear-ProxyBackup
}

function New-ProxyOverride {
    param([string]$Current)

    # Nao perder bypass corporativo; garante que localhost nunca volte pro proxy
    # (loop: navegador -> proxy local -> proxy local).
    $parts = @()
    if ($Current) { $parts = @($Current -split ';' | Where-Object { $_ }) }
    foreach ($need in @('<local>', '127.*', 'localhost')) {
        if ($parts -notcontains $need) { $parts += $need }
    }
    return ($parts -join ';')
}

function Enable-SystemProxy {
    $httpPort = Get-ScriptPort 'HttpPort' 10809

    # Proxy apontando p/ porta morta derruba a navegacao do usuario inteira.
    if (-not (Test-LocalPort -Port $httpPort)) {
        Write-Status "System proxy not enabled: nothing listening on 127.0.0.1:$httpPort (connect first)" "WARN"
        return $false
    }

    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    # Backup so na primeira vez: nao sobrescrever o original com o nosso proprio valor.
    if (-not (Test-Path $Script:ProxyBackupFile)) {
        $Script:ProxyBackupEnable = (Get-ItemProperty -Path $path -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        $Script:ProxyBackupServer = (Get-ItemProperty -Path $path -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
        $Script:ProxyBackupOverride = (Get-ItemProperty -Path $path -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride
        Save-ProxyBackup -Enable ([int]$Script:ProxyBackupEnable) -Server ([string]$Script:ProxyBackupServer) -Override ([string]$Script:ProxyBackupOverride)
    }

    # Sem entrada socks=: WinINET ignora e apps que leem o registro pegam lixo.
    Set-ProxyRegistry -Enable 1 -Server "http=127.0.0.1:$httpPort;https=127.0.0.1:$httpPort" -Override (New-ProxyOverride -Current ([string]$Script:ProxyBackupOverride))
    $Script:ProxyActive = $true
    Write-Status "System proxy enabled: http/https 127.0.0.1:$httpPort" "OK"
    return $true
}

function Disable-SystemProxy {
    # $Script:ProxyActive nao sobrevive a troca de runspace; o backup em disco sim.
    if (-not (Test-Path $Script:ProxyBackupFile) -and -not $Script:ProxyActive -and $null -eq $Script:ProxyBackupEnable) {
        Write-Status "System proxy is not under SettVPN control - nothing to restore" "INFO"
        return
    }

    $enable = $Script:ProxyBackupEnable
    $server = $Script:ProxyBackupServer
    $override = $Script:ProxyBackupOverride

    if (Test-Path $Script:ProxyBackupFile) {
        try {
            $obj = Get-Content $Script:ProxyBackupFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($obj) {
                $bEnable = Get-PropOr $obj 'Enable'
                $bServer = Get-PropOr $obj 'Server'
                $bOverride = Get-PropOr $obj 'Override'
                if ($null -ne $bEnable) { $enable = [int]$bEnable }
                if ($null -ne $bServer) { $server = [string]$bServer }
                if ($null -ne $bOverride) { $override = [string]$bOverride }
            }
        }
        catch { }
    }

    if ($null -ne $enable) {
        Set-ProxyRegistry -Enable ([int]$enable) -Server ([string]$server) -Override ([string]$override)
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

