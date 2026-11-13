# ============================================================
# Teste de integracao SettVPN (rede + v2ray reais)
# Roda:  powershell -NoProfile -ExecutionPolicy Bypass -File Tests\integration-tests.ps1
# Valida: baixa configs -> ping paralelo -> estabilidade -> geolocalizacao
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$fullPs1 = Join-Path $root 'Core\SettVPN_Full.ps1'

# --- setup dos $Script: usados pelas funcoes ---
$Script:TempDir = Join-Path $env:TEMP 'SettVPN'
$Script:ScriptFile = $fullPs1
$Script:V2RayExe = Join-Path $Script:TempDir 'v2ray.exe'
$Script:ConfigJson = Join-Path $Script:TempDir 'config.json'
$Script:ReadmeCache = Join-Path $Script:TempDir 'abc-configs-README.md'
$Script:SubCache = Join-Path $Script:TempDir 'pawdroid-sub.txt'
$Script:Sub2Cache = Join-Path $Script:TempDir 'peasoft-sub.txt'
$Script:AbcConfigsUrl = 'https://raw.githubusercontent.com/FreeFolksOn/abc-configs-free-vpn-proxy-list/main/README.md'
$Script:SubConfigsUrl = 'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub'
$Script:Sub2ConfigsUrl = 'https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list.txt'
$Script:V2RayProcess = $null
$Script:CurrentConfig = $null
$Script:ProxyActive = $false
$Script:TunStateFile = Join-Path $Script:TempDir 'tun-active.json'
$Script:TunReadyFile = Join-Path $Script:TempDir 'tun-ready.txt'
$Script:AppLog = Join-Path $Script:TempDir 'settvpn.log'
$Script:XrayLog = Join-Path $Script:TempDir 'xray.log'
$Script:KillSwitchBackup = Join-Path $Script:TempDir 'killswitch-backup.json'
$Script:SplitFile = Join-Path $Script:TempDir 'split-direct.txt'
$Script:GeoIpFile = Join-Path $Script:TempDir 'geoip.bin'
$Script:GeoIpData = $null
$Script:SocksPort = 10808
$Script:HttpPort = 10809
$Script:ApiPort = 10085
$Script:ScanPortBase = 20000
$Script:ExitIp = ''

$Sync = $null
$BadServers = @{}

if (-not (Test-Path $Script:V2RayExe)) {
    Write-Host "FALTA $($Script:V2RayExe) - rode o build antes" -ForegroundColor Red
    exit 1
}

# --- extrai funcoes ---
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPs1, [ref]$tokens, [ref]$errs)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$funcSource = ($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
Invoke-Expression $funcSource

Write-Host "== 1) Baixando configs ==" -ForegroundColor Cyan
$configs = Get-AllConfigs
if (-not $configs -or $configs.Count -eq 0) { Write-Host "FALHOU: nenhuma config" -ForegroundColor Red; exit 1 }
Write-Host "Configs apos filtro: $($configs.Count)" -ForegroundColor Green

Write-Host "`n== 2) Ping paralelo (TCP) ==" -ForegroundColor Cyan
$sorted = Get-ConfigsWithPing -Configs $configs
Write-Host "Alcancaveis: $($sorted.Count)" -ForegroundColor Green
if ($sorted.Count -eq 0) { Write-Host "FALHOU: nenhum alcancavel" -ForegroundColor Red; exit 1 }

Write-Host "`n== 3) Teste de estabilidade (12 servidores, janela 8s) ==" -ForegroundColor Cyan
$stable = @(Scan-StableServers -Configs $sorted -MaxToTest 12 -StabilitySeconds 8)
Write-Host "Estaveis: $($stable.Count)" -ForegroundColor $(if ($stable.Count -gt 0) { 'Green' } else { 'Red' })

Write-Host "`n== 4) Geolocalizacao ==" -ForegroundColor Cyan
Resolve-Countries -Configs $stable
foreach ($s in $stable) {
    $c = $s['Country']
    $cc = $s['CountryCode']
    Write-Host ("  {0} ({1}ms) - pais: [{2}] {3}" -f $s.Name, $s.Ping, $cc, $c)
}

Write-Host "`n== 5) Conexao real (primeiro estavel) ==" -ForegroundColor Cyan
if ($stable.Count -gt 0) {
    $ok = Start-V2Ray -Config $stable[0] -StabilitySeconds 3
    if ($ok) {
        Write-Host "CONECTADO: $($stable[0].Name)" -ForegroundColor Green
        Stop-V2Ray
    } else {
        Write-Host "FALHOU ao conectar no primeiro estavel" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Sem servidor estavel para testar conexao" -ForegroundColor Yellow
}

Write-Host "`nIntegracao concluida." -ForegroundColor Green
exit 0
