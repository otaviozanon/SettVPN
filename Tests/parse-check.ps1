$ErrorActionPreference = 'Stop'
foreach ($f in @('Core\SettVPN_Full.ps1','Core\SettVPN_Gui.ps1')) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$t, [ref]$e) | Out-Null
    if ($e -and $e.Count -gt 0) {
        Write-Host "$f : PARSE ERRORS" -ForegroundColor Red
        $e | ForEach-Object { Write-Host ("  " + $_.Extent.StartLineNumber + ": " + $_.Message) -ForegroundColor Red }
    } else {
        Write-Host "$f : OK" -ForegroundColor Green
    }
}
