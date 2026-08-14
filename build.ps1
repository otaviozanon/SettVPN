# ============================================================
# Gera icon.ico (raio dourado sobre fundo escuro, formato classico)
# e compila SettVPN.exe
# ============================================================

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$icoPath = Join-Path $root "Build\icon.ico"
$src     = Join-Path $root "Build\launcher.cs"
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

# ---- v2ray-core (baixado no build, nao commitado) ----
$v2rayVersion = "5.53.0"
$v2rayZipUrl  = "https://github.com/v2fly/v2ray-core/releases/download/v$v2rayVersion/v2ray-windows-64.zip"
$v2rayCache   = Join-Path $env:TEMP "SettVPN-build"
$v2rayExe     = Join-Path $v2rayCache "v2ray.exe"

if (-not (Test-Path $v2rayExe)) {
    Write-Host "Baixando v2ray-core v$v2rayVersion..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $v2rayCache -Force | Out-Null
    $zipPath = Join-Path $v2rayCache "v2ray.zip"
    Invoke-WebRequest -Uri $v2rayZipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $v2rayCache -Force
    Remove-Item $zipPath -Force
}
if (-not (Test-Path $v2rayExe)) { Write-Host "FALHA ao obter v2ray.exe" -ForegroundColor Red; exit 1 }
Write-Host "OK: v2ray.exe v$v2rayVersion ($([math]::Round((Get-Item $v2rayExe).Length/1MB,1)) MB)" -ForegroundColor Green

# ---- compila ----
$csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }

$fullPs1 = Join-Path $root "Core\SettVPN_Full.ps1"
$guiPs1  = Join-Path $root "Core\SettVPN_Gui.ps1"
$winIco  = Join-Path $root "Core\settvpn.ico"

if (-not (Test-Path $fullPs1)) { Write-Host "FALTA Core\SettVPN_Full.ps1" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $guiPs1))  { Write-Host "FALTA Core\SettVPN_Gui.ps1" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $winIco))  { Write-Host "FALTA Core\settvpn.ico" -ForegroundColor Red; exit 1 }

Write-Host "Compilando SettVPN.exe (self-contained)..." -ForegroundColor Cyan
& $csc /nologo /target:winexe /win32icon:"$icoPath" /out:"$out" "$src" `
    /resource:"$fullPs1" /resource:"$guiPs1" /resource:"$winIco" /resource:"$v2rayExe"

if (Test-Path $out) {
    Write-Host "OK: $out" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "FALHOU ao gerar SettVPN.exe" -ForegroundColor Red
    exit 1
}
