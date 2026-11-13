# ============================================================
# Gera icon.ico (raio dourado sobre fundo escuro, formato classico)
# e compila SettVPN.exe
# ============================================================

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$icoPath = Join-Path $root "Build\icon.ico"
$src     = Join-Path $root "Build\launcher.cs"
$manifest = Join-Path $root "Build\app.manifest"
$out     = Join-Path $root "SettVPN.exe"

function Get-IconImage {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    # fundo: quadrado escuro arredondado
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#141417"))
    $r = [int]($Size * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath($bg, $path)

    # raio dourado
    $font = New-Object System.Drawing.Font("Segoe UI Symbol", [float]($Size * 0.70), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#D4AF37"))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $g.DrawString([char]0x26A1, $font, $brush, $rect, $fmt)

    # extrai BGRA (top-down) e inverte para bottom-up
    $bmpRect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $bmpData = $bmp.LockBits($bmpRect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = [Math]::Abs($bmpData.Stride)
    $srcBytes = New-Object byte[] ($stride * $Size)
    [System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $srcBytes, 0, $srcBytes.Length)
    $bmp.UnlockBits($bmpData)

    $xor = New-Object byte[] ($stride * $Size)
    for ($y = 0; $y -lt $Size; $y++) {
        $srcRow = $y * $stride
        $dstRow = ($Size - 1 - $y) * $stride
        [System.Array]::Copy($srcBytes, $srcRow, $xor, $dstRow, $stride)
    }

    # mascara AND: toda zero (opaca; alpha vem do canal do XOR)
    $andStride = [int]((($Size + 31) -band (-bnot 31)) / 8)
    $and = New-Object byte[] ($andStride * $Size)

    $g.Dispose(); $bmp.Dispose(); $font.Dispose(); $brush.Dispose()
    $fmt.Dispose(); $path.Dispose(); $bg.Dispose()

    return @{ Xor = $xor; And = $and; Stride = $stride; AndStride = $andStride }
}

function Write-SingleIco {
    param([string]$Path, [int]$Size)

    $img = Get-IconImage -Size $Size
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([int16]0)
    $bw.Write([int16]1)
    $bw.Write([int16]1)

    $dataSize = 40 + ($img.Stride * $Size) + ($img.AndStride * $Size)
    $dim = if ($Size -ge 256) { 0 } else { $Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int32]$dataSize); $bw.Write([int32](6 + 16))

    $bw.Write([int32]40)
    $bw.Write([int32]$Size)
    $bw.Write([int32]($Size * 2))
    $bw.Write([int16]1)
    $bw.Write([int16]32)
    $bw.Write([int32]0)
    $bw.Write([int32]($img.Stride * $Size))
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write($img.Xor)
    $bw.Write($img.And)

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

Write-Host "Gerando icon.ico..." -ForegroundColor Cyan

$sizes = @(16, 32, 48, 256)
$images = @()
foreach ($s in $sizes) { $images += (Get-IconImage -Size $s) }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

$bw.Write([int16]0)                 # reserved
$bw.Write([int16]1)                 # type: icon
$bw.Write([int16]$sizes.Count)      # count

$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $img = $images[$i]
    $imgSize = 40 + ($img.Stride * $s) + ($img.AndStride * $s)
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim)
    $bw.Write([byte]$dim)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([int16]1)
    $bw.Write([int16]32)
    $bw.Write([int32]$imgSize)
    $bw.Write([int32]$offset)
    $offset += $imgSize
}

for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $img = $images[$i]

    $bw.Write([int32]40)                 # biSize
    $bw.Write([int32]$s)                 # biWidth
    $bw.Write([int32]($s * 2))           # biHeight (XOR + AND)
    $bw.Write([int16]1)                  # biPlanes
    $bw.Write([int16]32)                 # biBitCount
    $bw.Write([int32]0)                  # biCompression
    $bw.Write([int32]($img.Stride * $s)) # biSizeImage (XOR apenas)
    $bw.Write([int32]0)                  # x ppm
    $bw.Write([int32]0)                  # y ppm
    $bw.Write([int32]0)                  # clrUsed
    $bw.Write([int32]0)                  # clrImportant
    $bw.Write($img.Xor)
    $bw.Write($img.And)
}

$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Write-Host "OK: $icoPath ($([math]::Round((Get-Item $icoPath).Length/1KB)) KB)" -ForegroundColor Green

# icone da janela (taskbar) - embarcado no Core
$winIco = Join-Path $root "Core\settvpn.ico"
Write-SingleIco -Path $winIco -Size 48
Write-Host "OK: $winIco (window icon)" -ForegroundColor Green

# ---- Xray-core (fork do v2ray com suporte a TUN no Windows; baixado no build, nao commitado) ----
$xrayVersion = "26.3.27"
$xrayZipUrl  = "https://github.com/XTLS/Xray-core/releases/download/v$xrayVersion/Xray-windows-64.zip"
# Hashes do release v26.3.27 (fonte: Xray-windows-64.zip.dgst). Atualize junto com $xrayVersion.
$xrayZipSha256    = "d004c39288ce9ada487c6f398c7c545f7d749e44bdfdd59dbc9f865afba4e1ad"
$xrayExeSha256    = "15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1"
$xrayWintunSha256 = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce"
$xrayCache   = Join-Path $env:TEMP "SettVPN-build-xray"
$v2rayExe    = Join-Path $xrayCache "v2ray.exe"      # xray.exe renomeado (mantem compatibilidade com o codigo)
$wintunDll   = Join-Path $xrayCache "wintun.dll"

function Get-Sha256Text {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

$cacheOk = $false
if ((Test-Path $v2rayExe) -and (Test-Path $wintunDll)) {
    $cacheOk = ((Get-Sha256Text $v2rayExe) -eq $xrayExeSha256) -and ((Get-Sha256Text $wintunDll) -eq $xrayWintunSha256)
    if (-not $cacheOk) { Write-Host "Cache do Xray divergiu do hash esperado - baixando de novo" -ForegroundColor Yellow }
}

if (-not $cacheOk) {
    Write-Host "Baixando Xray-core v$xrayVersion..." -ForegroundColor Cyan
    if (Test-Path $xrayCache) { Remove-Item $xrayCache -Recurse -Force }
    New-Item -ItemType Directory -Path $xrayCache -Force | Out-Null
    $zipPath = Join-Path $xrayCache "xray.zip"
    Invoke-WebRequest -Uri $xrayZipUrl -OutFile $zipPath -UseBasicParsing

    $zipHash = Get-Sha256Text $zipPath
    if ($zipHash -ne $xrayZipSha256) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Host "FALHA: SHA256 do zip nao confere (esperado $xrayZipSha256, veio $zipHash)" -ForegroundColor Red
        exit 1
    }

    Expand-Archive -Path $zipPath -DestinationPath $xrayCache -Force
    Remove-Item $zipPath -Force

    $xrayExeFound = Get-ChildItem -Path $xrayCache -Recurse -Filter "xray.exe" | Select-Object -First 1
    $wintunFound  = Get-ChildItem -Path $xrayCache -Recurse -Filter "wintun.dll" | Select-Object -First 1

    # Renomeia xray.exe -> v2ray.exe (nomes distintos, sem risco de copiar sobre si)
    if ($xrayExeFound) {
        $target = Join-Path $xrayCache "v2ray.exe"
        if (Test-Path $target) { Remove-Item $target -Force }
        Copy-Item -LiteralPath $xrayExeFound.FullName -Destination $target -Force
    }

    # Garante wintun.dll na raiz do cache (zip pode extrair em subpasta)
    if ($wintunFound) {
        $target = Join-Path $xrayCache "wintun.dll"
        if (-not (Test-Path $target)) {
            Copy-Item -LiteralPath $wintunFound.FullName -Destination $target -Force
        }
    }
}
if (-not (Test-Path $v2rayExe)) { Write-Host "FALHA ao obter xray.exe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $wintunDll)) { Write-Host "FALHA ao obter wintun.dll" -ForegroundColor Red; exit 1 }
if ((Get-Sha256Text $v2rayExe) -ne $xrayExeSha256) { Write-Host "FALHA: SHA256 de v2ray.exe nao confere" -ForegroundColor Red; exit 1 }
if ((Get-Sha256Text $wintunDll) -ne $xrayWintunSha256) { Write-Host "FALHA: SHA256 de wintun.dll nao confere" -ForegroundColor Red; exit 1 }
Write-Host "OK: Xray v$xrayVersion ($([math]::Round((Get-Item $v2rayExe).Length/1MB,1)) MB) + wintun.dll (SHA256 verificado)" -ForegroundColor Green

# ---- GeoIP offline (DB-IP Lite country, CC BY 4.0) ----
# Formato embarcado: 10 bytes por registro IPv4 ordenado por inicio:
# start (uint32 LE) + end (uint32 LE) + codigo do pais (2 chars ASCII).
$dbIpVersion = "2026-11"
$dbIpUrl     = "https://download.db-ip.com/free/dbip-country-lite-$dbIpVersion.csv.gz"
$dbIpSha256  = "e5c8459d638a272ece7f4d7cfa49dce18d91b4f403f6940ba9249bf0db3781fd"
$geoCache    = Join-Path $env:TEMP "SettVPN-build-geoip"
$dbIpGz      = Join-Path $geoCache "dbip.csv.gz"
$geoBin      = Join-Path $geoCache "geoip.bin"

if (-not (Test-Path $dbIpGz) -or (Get-Sha256Text $dbIpGz) -ne $dbIpSha256) {
    Write-Host "Baixando GeoIP (DB-IP Lite $dbIpVersion)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $geoCache -Force | Out-Null
    Invoke-WebRequest -Uri $dbIpUrl -OutFile $dbIpGz -UseBasicParsing
    $dbIpHash = Get-Sha256Text $dbIpGz
    if ($dbIpHash -ne $dbIpSha256) {
        Remove-Item $dbIpGz -Force -ErrorAction SilentlyContinue
        Write-Host "FALHA: SHA256 do DB-IP nao confere (esperado $dbIpSha256, veio $dbIpHash)" -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $geoBin) -or (Get-Item $geoBin).LastWriteTime -lt (Get-Item $dbIpGz).LastWriteTime) {
    Write-Host "Convertendo GeoIP ($dbIpVersion) para binario..." -ForegroundColor Cyan
    # C#: o CSV tem ~1M linhas; laco em PowerShell levaria minutos.
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;

public static class SettVpnGeoIp
{
    public static int Convert(string gzPath, string outPath)
    {
        int count = 0;
        using (FileStream fs = File.OpenRead(gzPath))
        using (GZipStream gz = new GZipStream(fs, CompressionMode.Decompress))
        using (StreamReader sr = new StreamReader(gz))
        using (FileStream os = File.Create(outPath))
        using (BinaryWriter bw = new BinaryWriter(os))
        {
            string line;
            while ((line = sr.ReadLine()) != null)
            {
                string[] p = line.Split(',');
                if (p.Length < 3 || p[2].Length != 2) continue;
                IPAddress a, b;
                if (!IPAddress.TryParse(p[0], out a) || !IPAddress.TryParse(p[1], out b)) continue;
                byte[] ab = a.GetAddressBytes();
                byte[] bb = b.GetAddressBytes();
                if (ab.Length != 4 || bb.Length != 4) continue;
                bw.Write((uint)((ab[0] << 24) | (ab[1] << 16) | (ab[2] << 8) | ab[3]));
                bw.Write((uint)((bb[0] << 24) | (bb[1] << 16) | (bb[2] << 8) | bb[3]));
                byte[] cc = Encoding.ASCII.GetBytes(p[2].ToUpperInvariant());
                bw.Write(cc[0]);
                bw.Write(cc[1]);
                count++;
            }
        }
        return count;
    }
}
"@
    $geoCount = [SettVpnGeoIp]::Convert($dbIpGz, $geoBin)
    Write-Host "OK: geoip.bin ($geoCount registros, $([math]::Round((Get-Item $geoBin).Length/1MB,1)) MB)" -ForegroundColor Green
}
if (-not (Test-Path $geoBin)) { Write-Host "FALHA ao gerar geoip.bin" -ForegroundColor Red; exit 1 }

# ---- compila ----
# Versao do exe: tag do git (vX.Y.Z) ou SETTVPN_VERSION no CI. O Windows exige 4 partes.
$version = $env:SETTVPN_VERSION
if (-not $version) {
    try { $version = (& git -C $root describe --tags --abbrev=0 2>$null) } catch { }
}
$version = ([string]$version).Trim() -replace '^v', ''
if ($version -notmatch '^\d+\.\d+\.\d+') { $version = '1.0.0' }
$asmVersion = "$version.0"
$manifestVersioned = Join-Path $env:TEMP "SettVPN-manifest-$PID.xml"
# Sem BOM: manifest embutido com BOM quebra o SxS na inicializacao ("side-by-side configuration is incorrect").
$manifestXml = (Get-Content $manifest -Raw) -replace '<assemblyIdentity version="[0-9.]+"', "<assemblyIdentity version=`"$asmVersion`""
[System.IO.File]::WriteAllText($manifestVersioned, $manifestXml, (New-Object System.Text.UTF8Encoding($false)))

# Without these attributes the exe reports 0.0.0.0 in Explorer/Properties.
$asmInfo = Join-Path $env:TEMP "SettVPN-AssemblyInfo-$PID.cs"
@"
using System.Reflection;
[assembly: AssemblyTitle("SETT VPN")]
[assembly: AssemblyProduct("SETT VPN")]
[assembly: AssemblyVersion("$asmVersion")]
[assembly: AssemblyFileVersion("$asmVersion")]
[assembly: AssemblyInformationalVersion("$version")]
"@ | Set-Content -Path $asmInfo -Encoding UTF8

$csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }

$fullPs1 = Join-Path $root "Core\SettVPN_Full.ps1"
$guiPs1  = Join-Path $root "Core\SettVPN_Gui.ps1"
$winIco  = Join-Path $root "Core\settvpn.ico"

if (-not (Test-Path $fullPs1)) { Write-Host "FALTA Core\SettVPN_Full.ps1" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $guiPs1))  { Write-Host "FALTA Core\SettVPN_Gui.ps1" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $winIco))  { Write-Host "FALTA Core\settvpn.ico" -ForegroundColor Red; exit 1 }

# Referencia do PowerShell (Windows PowerShell 5.1 / .NET Framework 4.0) - compativel com o csc.exe 4.0.
# Nao usar a assembly do PowerShell 7 (Core/.NET 10): o csc.exe 4.0 nao referencia assemblies .NET 5+.
$psAsm = "C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll"
if (-not (Test-Path $psAsm)) {
    $psAsm = "C:\Windows\System32\WindowsPowerShell\v1.0\System.Management.Automation.dll"
}
if (-not (Test-Path $psAsm)) {
    try { $psAsm = [System.Management.Automation.PowerShell].Assembly.Location } catch { }
}
if (-not (Test-Path $psAsm)) { Write-Host "FALTA System.Management.Automation.dll" -ForegroundColor Red; exit 1 }

Write-Host "Compilando SettVPN.exe $asmVersion (self-contained, pede admin no launch)..." -ForegroundColor Cyan
& $csc /nologo /target:winexe /win32icon:"$icoPath" /win32manifest:"$manifestVersioned" /out:"$out" "$src" "$asmInfo" `
    /r:"$psAsm" `
    /resource:"$fullPs1" /resource:"$guiPs1" /resource:"$winIco" /resource:"$v2rayExe" /resource:"$wintunDll" /resource:"$geoBin"

# Sem isso um erro do csc (ex.: exe em uso) ainda imprimia "OK" com o binario antigo no disco.
if ($LASTEXITCODE -ne 0) {
    Write-Host "FALHOU ao compilar (csc exit $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

if (Test-Path $out) {
    Write-Host "OK: $out" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "FALHOU ao gerar SettVPN.exe" -ForegroundColor Red
    exit 1
}
