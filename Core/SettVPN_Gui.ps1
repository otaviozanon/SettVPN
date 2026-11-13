# ============================================================
# SettVPN - GUI (WPF)
# Deve ser dot-sourced pelo SettVPN_Full.ps1
# ============================================================

$Script:GuiFuncSource = $null

$Script:GuiSync = [hashtable]::Synchronized(@{
    State           = "idle"
    StatusText      = "Ready"
    Servers         = @()
    ConnectedConfig = $null
    Handle          = $null
    Worker          = $null
    Runspace        = $null
    OnComplete      = $null
    SelectedIndex   = -1
    Progress        = 0
    ScanTotal       = 0
    ScanTested      = 0
    ScanStart       = [DateTime]::MinValue
    ScanDeadline    = [DateTime]::MinValue
    TunEnabled      = $false
    Filtered        = $false
    ExitIp          = ""
    KillSwitch      = $false
    KsActive        = $false
})

function New-Brush {
    param([string]$Hex)
    return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)
}

function Initialize-GuiFuncSource {
    if ($Script:GuiFuncSource) { return }
    try {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script:ScriptFile, [ref]$tokens, [ref]$errs)
        $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $Script:GuiFuncSource = ($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    }
    catch {
        Write-Status "Failed to init GUI runspace source: $_" "ERROR"
    }
}

function Invoke-Background {
    param([string]$OpScript, [scriptblock]$OnComplete)

    $Script:GuiSync.State = "working"
    $Script:GuiSync.OnComplete = $OnComplete
    Set-GuiBusy $true

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('GuiSyncRef', $Script:GuiSync)
    $rs.SessionStateProxy.SetVariable('BadServersRef', $Script:BadServers)

    $worker = [powershell]::Create()
    $worker.Runspace = $rs

    $setup = @"
Set-StrictMode -Version Latest
`$Script:TempDir = '$($Script:TempDir)'
`$Script:ScriptFile = '$($Script:ScriptFile)'
`$Script:V2RayExe = '$($Script:V2RayExe)'
`$Script:WintunDll = '$($Script:WintunDll)'
`$Script:ConfigJson = '$($Script:ConfigJson)'
`$Script:XrayLog = '$($Script:XrayLog)'
`$Script:ReadmeCache = '$($Script:ReadmeCache)'
`$Script:SubCache = '$($Script:SubCache)'
`$Script:Sub2Cache = '$($Script:Sub2Cache)'
`$Script:AbcConfigsUrl = '$($Script:AbcConfigsUrl)'
`$Script:SubConfigsUrl = '$($Script:SubConfigsUrl)'
`$Script:Sub2ConfigsUrl = '$($Script:Sub2ConfigsUrl)'
`$Script:V2RayProcess = `$null
`$Script:CurrentConfig = `$null
`$Script:ProxyActive = `$false
`$Script:LastFailReason = `$null
`$Script:TunStopFile = `$null
`$Script:TunStateFile = '$($Script:TunStateFile)'
`$Script:TunReadyFile = '$($Script:TunReadyFile)'
`$Script:AppLog = '$($Script:AppLog)'
`$Script:KillSwitchBackup = '$($Script:KillSwitchBackup)'
`$Script:SplitFile = '$($Script:SplitFile)'
`$Script:GeoIpFile = '$($Script:GeoIpFile)'
`$Script:GeoIpData = `$null
`$Script:SocksPort = $($Script:SocksPort)
`$Script:HttpPort = $($Script:HttpPort)
`$Script:ApiPort = $($Script:ApiPort)
`$Script:ScanPortBase = $($Script:ScanPortBase)
`$Script:ExitIp = ''
`$Script:KillSwitch = `$false
`$Sync = `$GuiSyncRef
`$BadServers = `$BadServersRef
`$Script:KillSwitch = [bool]`$Sync.KillSwitch
`$ErrorActionPreference = 'Continue'
"@

    $override = @'
function Write-Status { param([string]$Message, [string]$Type = 'INFO'); $Sync.StatusText = $Message }
'@

    $full = $setup + "`n" + $Script:GuiFuncSource + "`n" + $override + "`n" + $OpScript

    try {
        [void]$worker.AddScript($full)
        $Script:GuiSync.Handle = $worker.BeginInvoke()
        $Script:GuiSync.Worker = $worker
        $Script:GuiSync.Runspace = $rs
    }
    catch {
        Write-Status "Background error: $_" "ERROR"
        $Script:GuiSync.State = "idle"
        Set-GuiBusy $false
        if ($rs) { try { $rs.Dispose() } catch {} }
    }
}

function Set-GuiBusy {
    param([bool]$Busy)
    if (-not $Script:GuiBtnConnect) { return }
    $Script:GuiBtnConnect.IsEnabled = (-not $Busy) -and $Script:ListReady
    $Script:GuiBtnChange.IsEnabled = -not $Busy
    $Script:GuiBtnDisconnect.IsEnabled = (-not $Busy) -and [bool]$Script:GuiSync.ConnectedConfig
    $Script:GuiBtnConnectSelected.IsEnabled = (-not $Busy) -and $Script:ListReady
    $Script:GuiBtnKs.IsEnabled = -not $Busy
    $Script:GuiBtnSplit.IsEnabled = -not $Busy
}

function Update-GuiStatus {
    $cfg = $Script:GuiSync.ConnectedConfig
    if ($cfg) {
        $Script:GuiLblStatus.Text = "CONNECTED"
        $Script:GuiLblStatus.Foreground = $Script:BrushGreen
        $Script:GuiDotStatus.Fill = $Script:BrushGreen
        $srvLabel = [string]$cfg.Name
        $country = [string]$cfg['Country']
        if ($country) { $srvLabel += "  ($country)" }
        $Script:GuiLblServer.Text = $srvLabel
        $pingLine = "Ping: $(Get-ServerPingMs -Config $cfg)ms  |  $($cfg.Protocol)  |  $($cfg.Host):$($cfg.Port)"
        if ($Script:GuiSync.ExitIp) { $pingLine += "  |  saida: $($Script:GuiSync.ExitIp)" }
        $Script:GuiLblPing.Text = $pingLine
    }
    else {
        $Script:GuiLblStatus.Text = "DISCONNECTED"
        $Script:GuiLblStatus.Foreground = $Script:BrushRed
        $Script:GuiDotStatus.Fill = $Script:BrushRed
        $Script:GuiLblServer.Text = "Not connected"
        $Script:GuiLblPing.Text = "Connect to hide your IP"
    }
    # Nao ha o que desconectar quando offline.
    if ($Script:GuiBtnDisconnect) {
        $Script:GuiBtnDisconnect.IsEnabled = [bool]$cfg -and $Script:GuiSync.State -ne "working"
    }
    if ($Script:GuiPnlTraffic) {
        $Script:GuiPnlTraffic.Visibility = if ($cfg) { 'Visible' } else { 'Collapsed' }
    }
    Sync-SystemProxy
}

function Sync-SystemProxy {
    # Conectar sem TUN nao muda o IP sozinho: o xray so abre proxy local. Aponta o
    # Windows para ele, senao o usuario ve "CONECTADO" com o IP real no navegador.
    if (-not $Script:GuiSync.ConnectedConfig) {
        $Script:ProxyAutoTried = $false
        if ($Script:ProxyAutoOn -and $Script:ProxyActive) {
            Disable-SystemProxy
            Update-ProxyButton
            Add-GuiLog "System proxy disabled (no connection)" "WARN"
        }
        $Script:ProxyAutoOn = $false
        return
    }
    if ($Script:GuiSync.TunEnabled -or $Script:ProxyActive -or $Script:ProxyAutoTried) { return }
    $Script:ProxyAutoTried = $true
    if (Enable-SystemProxy) {
        $Script:ProxyAutoOn = $true
        Update-ProxyButton
        Add-GuiLog "System proxy enabled: traffic going through the tunnel" "OK"
    }
    else {
        Add-GuiLog "System proxy not enabled: turn on TUN in settings" "WARN"
    }
}

function Update-ProxyButton {
    if ($Script:ProxyActive) {
        $Script:GuiBtnProxy.Content = "ON"
        $Script:GuiBtnProxy.Foreground = $Script:BrushGreen
        $Script:GuiBtnProxy.BorderBrush = $Script:BrushGreen
    }
    else {
        $Script:GuiBtnProxy.Content = "OFF"
        $Script:GuiBtnProxy.Foreground = $Script:BrushMuted
        $Script:GuiBtnProxy.BorderBrush = $Script:BrushBorder
    }
}

function Update-TunButton {
    if ($Script:GuiSync.TunEnabled) {
        $Script:GuiBtnTun.Content = "ON"
        $Script:GuiBtnTun.Foreground = $Script:BrushGreen
        $Script:GuiBtnTun.BorderBrush = $Script:BrushGreen
    }
    else {
        $Script:GuiBtnTun.Content = "OFF"
        $Script:GuiBtnTun.Foreground = $Script:BrushMuted
        $Script:GuiBtnTun.BorderBrush = $Script:BrushBorder
    }
}

function Update-KsButton {
    if ($Script:GuiSync.KillSwitch) {
        # Verde so quando o supervisor confirmou (arquivo de backup existe).
        $color = if ($Script:GuiSync.KsActive) { $Script:BrushGreen } else { $Script:BrushGold }
        $Script:GuiBtnKs.Content = "ON"
        $Script:GuiBtnKs.Foreground = $color
        $Script:GuiBtnKs.BorderBrush = $color
    }
    else {
        $Script:GuiBtnKs.Content = "OFF"
        $Script:GuiBtnKs.Foreground = $Script:BrushMuted
        $Script:GuiBtnKs.BorderBrush = $Script:BrushBorder
    }
}

function Update-SplitLabel {
    if (-not $Script:GuiLblSplit) { return }
    $n = @(Get-SplitDirectLines).Count
    $Script:GuiLblSplit.Text = if ($n -gt 0) { "$n direct rule(s) - TUN mode only" } else { "no rules - TUN mode only" }
}

function Start-GuiStats {
    if ($Script:StatsHandle) { return }
    $Script:StatsSync.Up = 0
    $Script:StatsSync.Down = 0
    $Script:StatsSync.Running = $true
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('StatsSyncRef', $Script:StatsSync)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $setup = "Set-StrictMode -Version Latest`n`$Script:V2RayExe = $(ConvertTo-PsLiteral $Script:V2RayExe)`n`$Script:ApiPort = $($Script:ApiPort)`n"
        $code = $setup + $Script:GuiFuncSource + "`n" + @'
$sync = $StatsSyncRef
while ($sync.Running) {
    $s = Get-TrafficStats
    if ($s) { $sync.Up = $s.Up; $sync.Down = $s.Down }
    Start-Sleep -Milliseconds 2000
}
'@
        [void]$ps.AddScript($code)
        $Script:StatsHandle = $ps.BeginInvoke()
        $Script:StatsPs = $ps
        $Script:StatsRs = $rs
    }
    catch {
        $Script:StatsSync.Running = $false
        Write-Status "Failed to start traffic stats: $_" "WARN"
    }
}

function Stop-GuiStats {
    $Script:StatsSync.Running = $false
}

function Complete-GuiStats {
    # Chamado pelo timer: a thread de stats dorme ate 2s antes de sair.
    if (-not $Script:StatsHandle -or -not $Script:StatsHandle.IsCompleted) { return }
    try { $Script:StatsPs.EndInvoke($Script:StatsHandle) } catch { }
    if ($Script:StatsRs) { try { $Script:StatsRs.Dispose() } catch { } }
    if ($Script:StatsPs) { try { $Script:StatsPs.Dispose() } catch { } }
    $Script:StatsHandle = $null
    $Script:StatsPs = $null
    $Script:StatsRs = $null
}

function Show-SplitDialog {
    $existing = ""
    if (Test-Path $Script:SplitFile) {
        try { $existing = [System.IO.File]::ReadAllText($Script:SplitFile).TrimEnd() } catch { }
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Split tunneling" Width="540" Height="440"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="#141417" ResizeMode="NoResize" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="Flat" TargetType="Button">
      <Setter Property="Width" Value="92"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#1E1E22"/>
      <Setter Property="Foreground" Value="#C5C5CC"/>
      <Setter Property="BorderBrush" Value="#2A2A30"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2A30"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Gold" TargetType="Button">
      <Setter Property="Width" Value="92"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#D4AF37"/>
      <Setter Property="Foreground" Value="#141417"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E0BE50"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#B8962F"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="18,14,18,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Foreground="#8A8A94" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"
               Text="One rule per line. Domains (netflix.com) and IPs/CIDRs (10.0.0.0/8) go DIRECT, outside the VPN. TUN mode only. Lines starting with # are ignored."/>
    <Border Grid.Row="1" Background="#0A0A0C" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="8">
      <TextBox x:Name="txtRules" AcceptsReturn="True" TextWrapping="NoWrap" Background="Transparent"
               BorderThickness="0" Foreground="#C5C5CC" CaretBrush="#D4AF37"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               FontFamily="Consolas" FontSize="12" Padding="10,8"/>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="btnCancel" Content="Cancel" Margin="0,0,8,0" Style="{StaticResource Flat}"/>
      <Button x:Name="btnOk" Content="Save" IsDefault="True" Style="{StaticResource Gold}"/>
    </StackPanel>
  </Grid>
</Window>
'@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $Script:SplitDialog = [Windows.Markup.XamlReader]::Load($reader)
        $Script:SplitDialog.Add_SourceInitialized({ param($s, $e) Set-DarkTitleBar $s })
    }
    catch {
        Add-GuiLog "Failed to open the editor: $_" "ERROR"
        return
    }

    $Script:SplitDialog.Owner = $Script:GuiWindow
    $Script:SplitDialogText = $Script:SplitDialog.FindName('txtRules')
    $Script:SplitDialogText.Text = $existing
    $Script:SplitDialogOk = $false

    $Script:SplitDialog.FindName('btnOk').Add_Click({
        $Script:SplitDialogOk = $true
        $Script:SplitDialog.Close()
    })
    $Script:SplitDialog.FindName('btnCancel').Add_Click({ $Script:SplitDialog.Close() })

    [void]$Script:SplitDialog.ShowDialog()

    if (-not $Script:SplitDialogOk) { return }
    $lines = @($Script:SplitDialogText.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    try {
        [System.IO.File]::WriteAllLines($Script:SplitFile, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Add-GuiLog "Split tunneling saved: $($lines.Count) direct rule(s)" "OK"
    }
    catch {
        Add-GuiLog "Failed to save split tunneling: $_" "ERROR"
        return
    }
    Update-SplitLabel

    if ($Script:GuiSync.ConnectedConfig -and $Script:GuiSync.TunEnabled) {
        Add-GuiLog "Reconnecting to apply split tunneling..." "INFO"
        Invoke-Background -OpScript $Script:tunToggleScript -OnComplete { Update-GuiStatus }
    }
    elseif ($lines.Count -gt 0) {
        Add-GuiLog "Turn on TUN mode for split tunneling to apply" "WARN"
    }
}

function Update-CountryFilter {
    if (-not $Script:GuiCbCountry) { return }

    $countries = @(@($Script:GuiSync.Servers) |
        ForEach-Object { [string]$_['Country'] } |
        Where-Object { $_ } |
        Sort-Object -Unique)
    $sig = $countries -join '|'
    if ($sig -eq $Script:CountrySignature) { return }
    $Script:CountrySignature = $sig

    # Selecao mudando nao deve repopular a lista no meio da atualizacao.
    $Script:CountryUpdating = $true
    try {
        $prev = [string]$Script:GuiCbCountry.SelectedItem
        $Script:GuiCbCountry.Items.Clear()
        [void]$Script:GuiCbCountry.Items.Add("All")
        foreach ($c in $countries) { [void]$Script:GuiCbCountry.Items.Add($c) }
        if ($prev -and $Script:GuiCbCountry.Items.Contains($prev)) { $Script:GuiCbCountry.SelectedItem = $prev }
        else { $Script:GuiCbCountry.SelectedIndex = 0 }
    }
    finally {
        $Script:CountryUpdating = $false
    }
}

function Populate-ServerList {
    $Script:GuiLstServers.Items.Clear()
    $style = $Script:GuiWindow.FindResource("ServerItemStyle")

    # Busca filtra a lista exibida; VisibleServers mantem o indice do item
    # selecionado apontando para o servidor certo.
    $q = ""
    if ($Script:GuiTxtSearch) { $q = ([string]$Script:GuiTxtSearch.Text).Trim().ToLowerInvariant() }
    Update-CountryFilter
    $servers = @($Script:GuiSync.Servers)
    $country = ""
    if ($Script:GuiCbCountry -and $Script:GuiCbCountry.SelectedItem) {
        $country = [string]$Script:GuiCbCountry.SelectedItem
    }
    if ($country -and $country -ne "All") {
        $servers = @($servers | Where-Object { [string]$_['Country'] -eq $country })
    }
    if ($q) {
        $servers = @($servers | Where-Object {
            ([string]$_.Name).ToLowerInvariant().Contains($q) -or
            ([string]$_[ 'Country']).ToLowerInvariant().Contains($q) -or
            ([string]$_.Host).ToLowerInvariant().Contains($q)
        })
    }
    if ($Script:SortDesc) { $servers = @($servers | Sort-Object { Get-ServerPingMs -Config $_ } -Descending) }
    $Script:VisibleServers = $servers
    if ($Script:GuiLblCount) {
        $total = @($Script:GuiSync.Servers).Count
        $filtering = [bool]$q -or ($country -and $country -ne "All")
        $Script:GuiLblCount.Text = if ($filtering) { "$($servers.Count) de $total" } else { "" }
    }

    if ($servers.Count -eq 0) {
        $ph = New-Object System.Windows.Controls.ListBoxItem
        $ph.Style = $style
        $ph.Content = if ($country -and $country -ne "All") { "No servers in $country" }
                      elseif ($q) { "No servers matching '$q'" }
                      elseif ($Script:GuiSync.Filtered) { "No working servers - click REFRESH again" }
                      else { "No servers - click REFRESH" }
        $ph.Foreground = $Script:BrushMuted
        $ph.FontSize = 12
        $ph.IsEnabled = $false
        $ph.Opacity = 0.6
        [void]$Script:GuiLstServers.Items.Add($ph)
        $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
        return
    }
    foreach ($cfg in $servers) {
        $ping = Get-ServerPingMs -Config $cfg
        if ($ping -lt 300) { $color = $Script:BrushGreen }
        elseif ($ping -lt 700) { $color = $Script:BrushGold }
        else { $color = $Script:BrushRed }

        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Style = $style
        $item.FontSize = 12

        $row = New-Object System.Windows.Controls.Grid
        $colPing = New-Object System.Windows.Controls.ColumnDefinition
        $colPing.Width = New-Object System.Windows.GridLength 50
        $colName = New-Object System.Windows.Controls.ColumnDefinition
        $colCountry = New-Object System.Windows.Controls.ColumnDefinition
        $colCountry.Width = New-Object System.Windows.GridLength 112
        [void]$row.ColumnDefinitions.Add($colPing)
        [void]$row.ColumnDefinitions.Add($colName)
        [void]$row.ColumnDefinitions.Add($colCountry)

        $tPing = New-Object System.Windows.Controls.TextBlock
        $tPing.Text = "$ping ms"
        $tPing.Foreground = $color
        $tPing.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tPing, 0)

        $tName = New-Object System.Windows.Controls.TextBlock
        $tName.Text = (Get-ShortName -Name ([string]$cfg.Name) -Max 34)
        $tName.Foreground = $Script:BrushText
        $tName.TextTrimming = "CharacterEllipsis"
        $tName.Margin = "8,0,0,0"
        $tName.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tName, 1)

        $country = [string]$cfg['Country']
        $tCountry = New-Object System.Windows.Controls.TextBlock
        $tCountry.Text = $country
        $tCountry.Foreground = $Script:BrushMuted
        $tCountry.TextTrimming = "CharacterEllipsis"
        $tCountry.TextAlignment = "Right"
        $tCountry.Margin = "10,0,0,0"
        $tCountry.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tCountry, 2)
        if (-not $country) { $tCountry.Visibility = "Collapsed" }

        [void]$row.Children.Add($tPing)
        [void]$row.Children.Add($tName)
        [void]$row.Children.Add($tCountry)
        $item.Content = $row
        [void]$Script:GuiLstServers.Items.Add($item)
    }
    $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
}

function Add-GuiLog {
    param([string]$Message, [string]$Type = "INFO")

    if (-not $Script:GuiLstLog) { return }

    $color = switch ($Type) {
        "OK"    { $Script:BrushGreen }
        "WARN"  { $Script:BrushGold }
        "ERROR" { $Script:BrushRed }
        default { $Script:BrushMuted }
    }

    $ts = Get-Date -Format "HH:mm:ss"
    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = "[$ts] $Message"
    $item.Foreground = $color
    $item.FontSize = 10
    [void]$Script:GuiLstLog.Items.Add($item)
    $Script:GuiLstLog.ScrollIntoView($item)
    while ($Script:GuiLstLog.Items.Count -gt 200) {
        $Script:GuiLstLog.Items.RemoveAt(0)
    }
    try { Write-AppLog -Message $Message -Type $Type } catch { }
}

function Start-GuiHealthCheck {
    if ($Script:HealthHandle) { return }

    $Script:HealthSync.Result = $null
    $Script:HealthSync.Busy = $true

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('HealthSyncRef', $Script:HealthSync)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $code = "`$Script:SocksPort = $($Script:SocksPort)`n" + $Script:GuiFuncSource + "`n" + @'
Set-StrictMode -Version Latest
$sync = $HealthSyncRef
$healthy = Test-V2RayTunnel
if ($healthy -and $sync.Tun) { $healthy = Test-V2RayTun }
$sync.Result = $healthy
$sync.Busy = $false
'@

        [void]$ps.AddScript($code)
        $Script:HealthHandle = $ps.BeginInvoke()
        $Script:HealthPs = $ps
        $Script:HealthRs = $rs
    }
    catch {
        $Script:HealthSync.Result = $false
        $Script:HealthSync.Busy = $false
    }
}

function Show-GuiWindow {
    if (-not $Script:GuiWindow) { return }
    $Script:GuiWindow.ShowInTaskbar = $true
    $Script:GuiWindow.Show()
    $Script:GuiWindow.WindowState = 'Normal'
    [void]$Script:GuiWindow.Activate()
}

# Barra de titulo padrao do Windows, porem no tema escuro do app (Win10 1809+ / Win11).
function Set-DarkTitleBar {
    param($Window)

    if (-not ("SettVpnDwm" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SettVpnDwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@
    }

    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        $on = 1
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (19 nas builds antigas)
        [void][SettVpnDwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)
        [void][SettVpnDwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)
        # Cores da barra no tom do app: COLORREF 0x00BBGGRR.
        $caption = 0x00171414   # #141417
        $text = 0x00EFEDED      # #EDEDEF
        $border = 0x00302A2A    # #2A2A30
        [void][SettVpnDwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$caption, 4)
        [void][SettVpnDwm]::DwmSetWindowAttribute($hwnd, 36, [ref]$text, 4)
        [void][SettVpnDwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$border, 4)
    }
    catch { }
}

function Start-SettVPN-Gui {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not ("SettVPNNative" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SettVPNNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
    }

    Initialize-Environment
    if (-not (Extract-V2Ray)) {
        Write-Status "Failed to initialize v2ray" "ERROR"
        return
    }
    Initialize-GuiFuncSource

    $Script:BrushGreen    = New-Brush "#3FB950"
    $Script:BrushRed      = New-Brush "#DA3633"
    $Script:BrushGold     = New-Brush "#D4AF37"
    $Script:BrushGoldHv   = New-Brush "#E0BE50"
    $Script:BrushGoldPress= New-Brush "#B8962F"
    $Script:BrushMuted    = New-Brush "#8A8A94"
    $Script:BrushText     = New-Brush "#C5C5CC"
    $Script:BrushBright   = New-Brush "#EDEDEF"
    $Script:BrushPanel    = New-Brush "#141417"
    $Script:BrushPanelHv  = New-Brush "#1E1E22"
    $Script:BrushBorder   = New-Brush "#2A2A30"
    $Script:BrushOnGold   = New-Brush "#141417"

    $Script:GuiSettings = $null
    $Script:GuiCbCountry = $null
    $Script:GuiBtnSort = $null
    $Script:GuiIcoSort = $null
    $Script:SortDesc = $false
    $Script:CountrySignature = $null
    $Script:CountryUpdating = $false
    $Script:VisibleServers = @()

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SETT VPN"
        Width="880" Height="632"
        Background="#0A0A0C"
        ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#D4AF37"/>
      <Setter Property="Foreground" Value="#141417"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E0BE50"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#B8962F"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="#1E1E22"/>
      <Setter Property="Foreground" Value="#C5C5CC"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderBrush" Value="#2A2A30"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2A30"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#141417"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ico" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
    </Style>
    <Style x:Key="DarkComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#C5C5CC"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bdi" Background="Transparent" CornerRadius="4" Margin="2,1">
              <ContentPresenter Margin="8,5"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bdi" Property="Background" Value="#2A2A30"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bdi" Property="Background" Value="#303036"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkCombo" TargetType="ComboBox">
      <Setter Property="Width" Value="126"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#C5C5CC"/>
      <Setter Property="Background" Value="#141417"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="6"/>
              <ContentPresenter Margin="10,0,24,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                TextElement.Foreground="#C5C5CC"/>
              <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="9" Foreground="#8A8A94"
                         HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0" IsHitTestVisible="False"/>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" Focusable="False"
                     AllowsTransparency="True" PopupAnimation="Fade">
                <Border Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="6" Margin="0,4,0,0" Width="126">
                  <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="240">
                    <StackPanel IsItemsHost="True" Margin="0,2"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="InfoBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A8A94"/>
      <Setter Property="Width" Value="18"/>
      <Setter Property="Height" Value="18"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#4A4A54" BorderThickness="1" CornerRadius="9" Width="{TemplateBinding Width}" Height="{TemplateBinding Height}">
              <TextBlock Text="i" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A30"/>
                <Setter Property="Foreground" Value="#D4AF37"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ServerItemStyle" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1E1E22"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#303036"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumbBorder" Background="#3A3A42" CornerRadius="4" Margin="1" MinHeight="24"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="thumbBorder" Property="Background" Value="#4A4A54"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="thumbBorder" Property="Background" Value="#4A4A54"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="24,20,24,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="22"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Grid Grid.Column="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="10" Padding="18,18">
          <StackPanel>
            <Border Width="54" Height="54" CornerRadius="27" Background="#1E1E22" BorderBrush="#2A2A30" BorderThickness="1" HorizontalAlignment="Center">
              <TextBlock Text="&#9889;" FontSize="22" Foreground="#D4AF37" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
              <Ellipse x:Name="dotStatus" Width="8" Height="8" Fill="#DA3633" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock x:Name="lblStatus" Text="DISCONNECTED" FontSize="13" FontWeight="SemiBold" Foreground="#DA3633" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="lblServer" Text="Not connected" FontSize="13" Foreground="#EDEDEF" HorizontalAlignment="Center" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="lblPing" Text="Connect to hide your IP" FontSize="11" Foreground="#8A8A94" HorizontalAlignment="Center" Margin="0,4,0,0" TextWrapping="Wrap" TextAlignment="Center"/>
            <StackPanel x:Name="pnlTraffic" Visibility="Collapsed">
              <Border Height="1" Background="#2A2A30" Margin="0,14,0,0"/>
              <TextBlock x:Name="lblTraffic" Text="↓ 0 B   ↑ 0 B" FontSize="11" Foreground="#D4AF37" HorizontalAlignment="Center" Margin="0,10,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Button Grid.Row="1" x:Name="btnConnect" Height="46" Margin="0,14,0,0" Style="{StaticResource PrimaryBtn}"
                AutomationProperties.Name="CONNECT">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Ico}" Text="&#xE7E8;" FontSize="15"/>
            <TextBlock Text="CONNECT" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>

        <Button Grid.Row="2" x:Name="btnChange" Height="34" Margin="0,8,0,0" Style="{StaticResource GhostBtn}" AutomationProperties.Name="REFRESH"
                ToolTip="Fetch the list, test TCP+UDP and keep only working servers (~1 min)">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Ico}" Text="&#xE72C;"/>
            <TextBlock Text="REFRESH" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>

        <Button Grid.Row="3" x:Name="btnDisconnect" Height="34" Margin="0,8,0,0" Style="{StaticResource GhostBtn}" AutomationProperties.Name="DISCONNECT">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Ico}" Text="&#xE711;"/>
            <TextBlock Text="DISCONNECT" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>

        <Border Grid.Row="4" MinHeight="150" Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="10" Padding="12,10,12,10" Margin="0,14,0,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="ACTIVITY" FontSize="10" FontWeight="SemiBold" Foreground="#8A8A94" VerticalAlignment="Center"/>
              <Button x:Name="btnCopyLog" Grid.Column="1" Width="26" Height="24" Padding="0" Style="{StaticResource GhostBtn}"
                      AutomationProperties.Name="COPY" ToolTip="Copy activity">
                <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#C5C5CC"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Button>
            </Grid>
            <Border Grid.Row="1" Background="#0A0A0C" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="6" Padding="2">
              <ListBox x:Name="lstLog" Background="Transparent" Foreground="#8A8A94" BorderThickness="0" FontSize="10"
                       MinHeight="80" Padding="4,2" ScrollViewer.VerticalScrollBarVisibility="Visible"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled" Focusable="False"/>
            </Border>
            <StackPanel x:Name="pnlProgress" Grid.Row="2" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
              <TextBlock Text="PROGRESS" FontSize="10" FontWeight="SemiBold" Foreground="#8A8A94"/>
              <TextBlock x:Name="lblProgress" Text="" FontSize="10" Foreground="#D4AF37" Margin="8,0,0,0"/>
            </StackPanel>
            <ProgressBar Grid.Row="3" x:Name="pbScan" Height="6" Margin="0,5,0,0" Background="#1E1E22" Foreground="#D4AF37" BorderThickness="0" Minimum="0" Maximum="100" Value="0" Visibility="Collapsed"/>
          </Grid>
        </Border>
      </Grid>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="6" Height="32">
            <Grid>
              <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#5A5A64" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <TextBox x:Name="txtSearch" Background="Transparent" BorderThickness="0" Foreground="#C5C5CC" FontSize="12"
                       Margin="30,0,10,0" VerticalAlignment="Center" CaretBrush="#D4AF37"/>
              <TextBlock x:Name="lblSearchHint" Text="Search country or name" FontSize="12" Foreground="#5A5A64"
                         Margin="30,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </Border>
          <ComboBox x:Name="cbCountry" Grid.Column="1" Margin="8,0,0,0" Style="{StaticResource DarkCombo}"
                    AutomationProperties.Name="Filter by country" ToolTip="Show only servers from this country"/>
          <Button x:Name="btnSort" Grid.Column="2" Width="32" Height="32" Margin="8,0,0,0" Style="{StaticResource GhostBtn}"
                  AutomationProperties.Name="SORT" ToolTip="Sort by latency">
            <TextBlock x:Name="icoSort" Text="&#xE70E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#C5C5CC"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Button>
          <TextBlock x:Name="lblCount" Grid.Column="3" Text="" FontSize="11" Foreground="#8A8A94" VerticalAlignment="Center" Margin="10,0,2,0"/>
        </Grid>

        <Border Grid.Row="1" Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="10">
          <ListBox x:Name="lstServers" Background="Transparent" BorderThickness="0" Foreground="#C5C5CC" FontSize="12" Margin="6"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled" ItemContainerStyle="{StaticResource ServerItemStyle}"/>
        </Border>

        <Button x:Name="btnConnectSelected" Grid.Row="2" Height="36" Margin="0,10,0,0" Style="{StaticResource GhostBtn}"
                AutomationProperties.Name="CONNECT SELECTED">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Ico}" Text="&#xE768;"/>
            <TextBlock Text="CONNECT SELECTED" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>
    </Grid>

    <Border Grid.Row="1" BorderBrush="#2A2A30" BorderThickness="0,1,0,0" Background="#141417" Padding="20,8,20,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="lblLog" Text="Ready" Foreground="#8A8A94" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <Button x:Name="btnSettings" Grid.Column="1" MinWidth="152" Height="30" Padding="14,0" Style="{StaticResource GhostBtn}"
                AutomationProperties.Name="Settings" ToolTip="Proxy, TUN, kill switch and split tunneling">
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Ico}" Text="&#xE713;" FontSize="12"/>
            <TextBlock Text="Settings" FontSize="11" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $Script:GuiWindow = [Windows.Markup.XamlReader]::Load($reader)
    $Script:GuiWindow.Add_SourceInitialized({ param($s, $e) Set-DarkTitleBar $s })

    # Ajustes em janela propria: os quatro controles nao competem com o botao de
    # conectar (modelo dos VPNs pagos: tela limpa, ajustes a parte).
    [xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="480" Height="262"
        Background="#141417"
        ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner">
  <Window.Resources>
    <Style x:Key="SettingToggle" TargetType="Button">
      <Setter Property="Width" Value="62"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#1E1E22"/>
      <Setter Property="Foreground" Value="#C5C5CC"/>
      <Setter Property="BorderBrush" Value="#2A2A30"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2A30"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Info" TargetType="Button">
      <Setter Property="Width" Value="16"/>
      <Setter Property="Height" Value="16"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A8A94"/>
      <Setter Property="BorderBrush" Value="#3A3A42"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
              <TextBlock Text="i" FontSize="9" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A30"/>
                <Setter Property="Foreground" Value="#D4AF37"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <StackPanel Margin="16,12,16,14">
      <Grid Margin="0,4,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="System proxy" Foreground="#EDEDEF" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnInfoProxy" Style="{StaticResource Info}" ToolTip="Detalhes"/>
          </StackPanel>
          <TextBlock x:Name="lblPorts" Text="SOCKS5 :10808  ·  HTTP :10809" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
        </StackPanel>
        <Button x:Name="btnProxy" Grid.Column="1" Content="OFF" Style="{StaticResource SettingToggle}"/>
      </Grid>
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="TUN mode (all traffic)" Foreground="#EDEDEF" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnInfoTun" Style="{StaticResource Info}" ToolTip="Detalhes"/>
          </StackPanel>
          <TextBlock Text="Routes Discord/voice and everything else" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
        </StackPanel>
        <Button x:Name="btnTun" Grid.Column="1" Content="OFF" Style="{StaticResource SettingToggle}"/>
      </Grid>
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Kill switch" Foreground="#EDEDEF" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnInfoKs" Style="{StaticResource Info}" ToolTip="Detalhes"/>
          </StackPanel>
          <TextBlock x:Name="lblKs" Text="blocks everything outside the tunnel" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
        </StackPanel>
        <Button x:Name="btnKs" Grid.Column="1" Content="OFF" Style="{StaticResource SettingToggle}"/>
      </Grid>
      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Split tunneling" Foreground="#EDEDEF" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnInfoSplit" Style="{StaticResource Info}" ToolTip="Detalhes"/>
          </StackPanel>
          <TextBlock x:Name="lblSplit" Text="no rules" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
        </StackPanel>
        <Button x:Name="btnSplit" Grid.Column="1" Content="EDIT" Style="{StaticResource SettingToggle}"/>
      </Grid>
      <TextBlock Text="Kill switch and split tunneling only work in TUN mode." Foreground="#6A6A74" FontSize="10" Margin="0,16,0,0" TextWrapping="Wrap"/>
    </StackPanel>
  </Grid>
</Window>
'@

    try {
        $sReader = New-Object System.Xml.XmlNodeReader $settingsXaml
        $Script:GuiSettings = [Windows.Markup.XamlReader]::Load($sReader)
        $Script:GuiSettings.Add_SourceInitialized({ param($s, $e) Set-DarkTitleBar $s })
        # X da barra padrao: so esconde (reabrir depois usa a mesma janela).
        $Script:GuiSettings.Add_Closing({
            param($sender, $e)
            if (-not $Script:AllowClose) {
                $e.Cancel = $true
                $sender.Hide()
            }
        })
    }
    catch {
        Write-Status "Failed to create the settings window: $_" "ERROR"
    }

    $Script:AppIcon = $null
    try {
        $exePath = $env:SETTVPN_EXE
        if ($exePath -and (Test-Path $exePath)) {
            $Script:AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        }
    }
    catch { }
    if (-not $Script:AppIcon) {
        try {
            $ico = Join-Path $Script:ScriptDir "settvpn.ico"
            if (Test-Path $ico) { $Script:AppIcon = New-Object System.Drawing.Icon($ico) }
        }
        catch { }
    }
    if ($Script:AppIcon) {
        try {
            $Script:GuiWindow.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $Script:AppIcon.Handle,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
        }
        catch { }
    }

    $Script:GuiLblStatus        = $Script:GuiWindow.FindName("lblStatus")
    $Script:GuiDotStatus        = $Script:GuiWindow.FindName("dotStatus")
    $Script:GuiLblServer        = $Script:GuiWindow.FindName("lblServer")
    $Script:GuiLblPing          = $Script:GuiWindow.FindName("lblPing")
    $Script:GuiLblPorts         = $Script:GuiSettings.FindName("lblPorts")
    if ($Script:GuiLblPorts) {
        $Script:GuiLblPorts.Text = "SOCKS5 :$($Script:SocksPort)  ·  HTTP :$($Script:HttpPort)"
    }
    $Script:GuiLblLog           = $Script:GuiWindow.FindName("lblLog")
    $Script:GuiLstServers       = $Script:GuiWindow.FindName("lstServers")
    $Script:GuiLstLog           = $Script:GuiWindow.FindName("lstLog")
    $Script:GuiPbScan           = $Script:GuiWindow.FindName("pbScan")
    $Script:GuiPnlProgress      = $Script:GuiWindow.FindName("pnlProgress")
    $Script:GuiLblProgress      = $Script:GuiWindow.FindName("lblProgress")
    $Script:GuiBtnProxy         = $Script:GuiSettings.FindName("btnProxy")
    $Script:GuiBtnTun           = $Script:GuiSettings.FindName("btnTun")
    $Script:GuiBtnKs            = $Script:GuiSettings.FindName("btnKs")
    $Script:GuiBtnSplit         = $Script:GuiSettings.FindName("btnSplit")
    $Script:GuiLblTraffic       = $Script:GuiWindow.FindName("lblTraffic")
    $Script:GuiPnlTraffic       = $Script:GuiWindow.FindName("pnlTraffic")
    $Script:GuiLblKs            = $Script:GuiSettings.FindName("lblKs")
    $Script:GuiLblSplit         = $Script:GuiSettings.FindName("lblSplit")
    $Script:GuiBtnInfoKs        = $Script:GuiSettings.FindName("btnInfoKs")
    $Script:GuiBtnInfoSplit     = $Script:GuiSettings.FindName("btnInfoSplit")
    $Script:GuiBtnInfoProxy     = $Script:GuiSettings.FindName("btnInfoProxy")
    $Script:GuiBtnInfoTun       = $Script:GuiSettings.FindName("btnInfoTun")
    $Script:GuiBtnSettings      = $Script:GuiWindow.FindName("btnSettings")
    $Script:GuiTxtSearch        = $Script:GuiWindow.FindName("txtSearch")
    $Script:GuiLblSearchHint    = $Script:GuiWindow.FindName("lblSearchHint")
    $Script:GuiCbCountry        = $Script:GuiWindow.FindName("cbCountry")
    $Script:GuiBtnSort          = $Script:GuiWindow.FindName("btnSort")
    $Script:GuiIcoSort          = $Script:GuiWindow.FindName("icoSort")
    $Script:GuiLblCount         = $Script:GuiWindow.FindName("lblCount")
    $Script:GuiBtnConnect       = $Script:GuiWindow.FindName("btnConnect")
    $Script:GuiBtnChange        = $Script:GuiWindow.FindName("btnChange")
    $Script:GuiBtnDisconnect    = $Script:GuiWindow.FindName("btnDisconnect")
    $Script:GuiBtnConnectSelected = $Script:GuiWindow.FindName("btnConnectSelected")
    $Script:GuiBtnCopyLog       = $Script:GuiWindow.FindName("btnCopyLog")

    # Tray icon: fecha janela -> continua rodando na bandeja
    $Script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $Script:TrayIcon.Text = "SETT VPN"
    if ($Script:AppIcon) {
        $Script:TrayIcon.Icon = $Script:AppIcon
    }
    $Script:TrayIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $menuOpen = New-Object System.Windows.Forms.ToolStripMenuItem "Open"
    $menuConnect = New-Object System.Windows.Forms.ToolStripMenuItem "Connect"
    $menuDisconnect = New-Object System.Windows.Forms.ToolStripMenuItem "Disconnect"
    $menuTun = New-Object System.Windows.Forms.ToolStripMenuItem "TUN mode (on/off)"
    $menuExit = New-Object System.Windows.Forms.ToolStripMenuItem "Exit"
    $menuOpen.Add_Click({
        Show-GuiWindow
    })
    $menuConnect.Add_Click({
        $Script:GuiWindow.Dispatcher.Invoke([action]{
            $Script:GuiBtnConnect.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        })
    })
    $menuDisconnect.Add_Click({
        $Script:GuiWindow.Dispatcher.Invoke([action]{
            $Script:GuiBtnDisconnect.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        })
    })
    $menuTun.Add_Click({
        $Script:GuiWindow.Dispatcher.Invoke([action]{
            $Script:GuiBtnTun.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        })
    })
    $menuExit.Add_Click({
        $Script:AllowClose = $true
        try { $Script:GuiWindow.Close() } catch {}
        if ($Script:MainFrame) { $Script:MainFrame.Continue = $false }
    })
    [void]$trayMenu.Items.Add($menuOpen)
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$trayMenu.Items.Add($menuConnect)
    [void]$trayMenu.Items.Add($menuDisconnect)
    [void]$trayMenu.Items.Add($menuTun)
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$trayMenu.Items.Add($menuExit)
    $Script:TrayIcon.ContextMenuStrip = $trayMenu
    $Script:TrayIcon.Add_DoubleClick({
        Show-GuiWindow
    })

    # Health check state
    $Script:HealthSync = [hashtable]::Synchronized(@{ Busy = $false; Result = $null; Tun = $false })
    $Script:HealthHandle = $null
    $Script:HealthPs = $null
    $Script:HealthRs = $null
    $Script:LastHealthCheck = [DateTime]::MinValue
    $Script:BadServers = [hashtable]::Synchronized(@{})
    $Script:ListReady = $false
    $Script:AllowClose = $false

    # Estatisticas: runspace persistente em loop (criar runspace a cada 2s custa caro).
    $Script:StatsSync = [hashtable]::Synchronized(@{ Up = 0; Down = 0; Running = $false })
    $Script:StatsHandle = $null
    $Script:StatsPs = $null
    $Script:StatsRs = $null
    $Script:VisibleServers = @()
    $Script:ProxyAutoTried = $false
    $Script:ProxyAutoOn = $false
    $Script:SplitDialog = $null
    $Script:SplitDialogText = $null
    $Script:SplitDialogOk = $false

    # Segunda instancia avisa por evento nomeado; o launcher cria/sinaliza.
    $Script:ActivateEvent = $null
    try {
        $Script:ActivateEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "SettVPN_Activate")
    }
    catch { }

    $Script:connectScript = @'
if (-not $Sync.Servers -or $Sync.Servers.Count -eq 0) { $Sync.StatusText = "Refresh the list first"; return }
# Amostra espalhada: os de menor ping sao CDN/Cloudflare com caminho morto.
$cands = @(Get-SpreadSample -Items @($Sync.Servers) -Max 12)
$tries = 0
foreach ($cfg in $cands) {
    $tries++
    $Sync.StatusText = "Connecting ($tries/$($cands.Count)): $(Get-ShortName $cfg.Name)"
    if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.ExitIp = $Script:ExitIp; $Sync.StatusText = "Connected: $(Get-ShortName $cfg.Name)"; return }
}
$Sync.ConnectedConfig = $null
$Sync.ExitIp = ""
$Sync.StatusText = if ($Script:LastFailReason) { "Failed after $($tries): $($Script:LastFailReason)" } else { "Failed on $tries servers - click REFRESH" }
'@

    $Script:reconnectScript = @'
# Prioriza os servidores ja validados como estaveis (pool atual)
$now = [DateTime]::Now
$pool = @($Sync.Servers | Where-Object { $k = "$($_.Host):$($_.Port)"; -not ($BadServers.ContainsKey($k) -and (($now - $BadServers[$k]).TotalMinutes -lt 5)) })
$pool = @($pool | Sort-Object -Property @{ Expression = { [int]$_.Ping } })
if ($pool.Count -gt 0) {
    foreach ($cfg in $pool) {
        $Sync.StatusText = "Trying: $(Get-ShortName $cfg.Name) ($($cfg.Ping)ms)"
        if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.ExitIp = $Script:ExitIp; $Sync.StatusText = "Connected: $(Get-ShortName $cfg.Name)"; return }
    }
}

# Fallback: pool esgotado -> refaz do mesmo modo (filtrado ou nao)
$Sync.StatusText = "Pool exhausted - rebuilding..."
$candidates = Get-ServerPool -Filtered $Sync.Filtered -BadServers $BadServers
if (-not $candidates -or $candidates.Count -eq 0) { $Sync.ConnectedConfig = $null; $Sync.StatusText = "No servers found"; return }
$Sync.Servers = $candidates
foreach ($cfg in $candidates) {
    $Sync.StatusText = "Trying: $(Get-ShortName $cfg.Name) ($($cfg.Ping)ms)"
    if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.ExitIp = $Script:ExitIp; $Sync.StatusText = "Connected: $(Get-ShortName $cfg.Name)"; return }
}
$Sync.ConnectedConfig = $null
$Sync.ExitIp = ""
$Sync.StatusText = if ($Script:LastFailReason) { "All failed: $Script:LastFailReason" } else { "All servers failed" }
'@

    $Script:refreshScript = @'
# Baixar + pingar todos e testar estabilidade (TCP+UDP) de uma amostra espalhada:
# a lista que chega na tela so tem servidor que realmente passa trafego.
$pool = Get-ServerPool -Filtered $true -BadServers $BadServers
$Sync.Filtered = $true
if (-not $pool -or $pool.Count -eq 0) { $Sync.Servers = @(); $Sync.StatusText = "No working servers"; return }
$Sync.Servers = $pool
$Sync.StatusText = "Working servers: $($pool.Count)"
'@

    $Script:connectSelectedScript = @'
$idx = $Sync.SelectedIndex
if ($idx -lt 0 -or $idx -ge $Sync.Servers.Count) { $Sync.StatusText = "No server selected"; return }
$cfg = $Sync.Servers[$idx]
$Sync.StatusText = "Connecting: $(Get-ShortName $cfg.Name)"
if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.ExitIp = $Script:ExitIp; $Sync.StatusText = "Connected: $(Get-ShortName $cfg.Name)" }
else { $Sync.ConnectedConfig = $null; $Sync.ExitIp = ""; $Sync.StatusText = if ($Script:LastFailReason) { $Script:LastFailReason } else { "Failed to connect to $(Get-ShortName $cfg.Name)" } }
'@

    $Script:tunToggleScript = @'
$cfg = $Sync.ConnectedConfig
if (-not $cfg) {
    $Sync.StatusText = if ($Sync.TunEnabled) { "TUN mode on (applies on connect)" } else { "TUN mode off" }
    return
}
$Sync.StatusText = if ($Sync.TunEnabled) { "Reconnecting with TUN..." } else { "Reconnecting without TUN..." }
if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) {
    $Sync.ConnectedConfig = $cfg
    $Sync.ExitIp = $Script:ExitIp
    $Sync.StatusText = if ($Sync.TunEnabled) { "Connected (TUN ON)" } else { "Connected (TUN OFF)" }
}
else {
    $Sync.ConnectedConfig = $null
    $Sync.ExitIp = ""
    $Sync.StatusText = if ($Script:LastFailReason) { "Reconnect failed: $Script:LastFailReason" } else { "Reconnect failed with TUN mode" }
}
'@

    $Script:GuiBtnConnect.Add_Click({
        $Script:GuiLblLog.Text = "Connecting..."
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "System proxy re-enabled on connect" "INFO" }
        Add-GuiLog "Connecting (trying servers)..." "INFO"
        Invoke-Background -OpScript $Script:connectScript -OnComplete {
            Update-GuiStatus; Populate-ServerList
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Connected: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
            }
            else {
                Add-GuiLog "Failed: $($Script:GuiSync.StatusText)" "ERROR"
            }
        }
    })

    $Script:GuiBtnChange.Add_Click({
        $Script:GuiLblLog.Text = "Refreshing and testing servers..."
        $Script:GuiSync.Progress = 0
        $Script:GuiSync.ScanTotal = 0
        $Script:GuiSync.ScanTested = 0
        $Script:GuiSync.ScanStart = [DateTime]::MinValue
        $Script:GuiSync.ScanDeadline = [DateTime]::MinValue
        Add-GuiLog "Downloading list and testing (TCP+UDP)..." "INFO"
        Invoke-Background -OpScript $Script:refreshScript -OnComplete {
            Populate-ServerList
            $Script:ListReady = $true
            Set-GuiBusy $false
            Add-GuiLog "$($Script:GuiSync.Servers.Count) working servers" "OK"
        }
    })

    $Script:GuiBtnConnectSelected.Add_Click({
        $idx = $Script:GuiLstServers.SelectedIndex
        if ($idx -lt 0 -or $idx -ge @($Script:VisibleServers).Count) { $Script:GuiLblLog.Text = "Select a server in the list"; return }
        $cfg = $Script:VisibleServers[$idx]
        $Script:GuiSync.SelectedIndex = [array]::IndexOf(@($Script:GuiSync.Servers), $cfg)
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "System proxy re-enabled on connect" "INFO" }
        Add-GuiLog "Connecting: $($cfg.Name)" "INFO"
        Invoke-Background -OpScript $Script:connectSelectedScript -OnComplete {
            Update-GuiStatus
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Connected: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
            }
            else {
                Add-GuiLog "Failed: $($Script:GuiSync.StatusText)" "ERROR"
            }
        }
    })

    $Script:GuiBtnDisconnect.Add_Click({
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "System proxy disabled" "WARN" }
        if ($Script:GuiSync.TunEnabled) { $Script:GuiSync.TunEnabled = $false; Update-TunButton; Add-GuiLog "TUN mode off" "WARN" }
        if ($Script:GuiSync.KillSwitch) { $Script:GuiSync.KillSwitch = $false; Update-KsButton; Add-GuiLog "Kill switch off" "WARN" }
        Stop-V2Ray
        $Script:GuiSync.ConnectedConfig = $null
        $Script:GuiSync.ExitIp = ""
        Update-GuiStatus
        $Script:GuiLblLog.Text = "Disconnected"
        Add-GuiLog "Disconnected" "WARN"
    })

    $Script:GuiBtnProxy.Add_Click({
        $Script:ProxyAutoOn = $false
        if ($Script:ProxyActive) {
            Disable-SystemProxy
            Update-ProxyButton
            Add-GuiLog "System proxy disabled" "WARN"
        }
        else {
            if ($Script:GuiSync.TunEnabled) {
                $Script:GuiSync.TunEnabled = $false
                Update-TunButton
                Add-GuiLog "TUN mode off (proxy active)" "WARN"
            }
            if ($Script:GuiSync.KillSwitch) {
                $Script:GuiSync.KillSwitch = $false
                Update-KsButton
                Add-GuiLog "Kill switch off (requires TUN mode)" "WARN"
            }
            if (-not (Enable-SystemProxy)) {
                Update-ProxyButton
                Add-GuiLog "System proxy not enabled: connect first" "ERROR"
                return
            }
            Update-ProxyButton
            Add-GuiLog "System proxy enabled (HTTP 127.0.0.1:$($Script:HttpPort))" "OK"
            Add-GuiLog "Discord voice (UDP) bypasses the proxy - use TUN mode" "WARN"
            if ($Script:GuiSync.ConnectedConfig) {
                Invoke-Background -OpScript $Script:tunToggleScript -OnComplete { Update-GuiStatus }
            }
        }
    })

    $Script:GuiBtnTun.Add_Click({
        $Script:GuiSync.TunEnabled = -not $Script:GuiSync.TunEnabled
        Update-TunButton
        if (-not $Script:GuiSync.TunEnabled -and $Script:GuiSync.KillSwitch) {
            $Script:GuiSync.KillSwitch = $false
            Update-KsButton
            Add-GuiLog "Kill switch off (requires TUN mode)" "WARN"
        }
        if ($Script:GuiSync.TunEnabled) {
            if ($Script:ProxyActive) {
                Disable-SystemProxy
                Update-ProxyButton
                Add-GuiLog "Proxy off (TUN covers the whole network)" "WARN"
            }
            Add-GuiLog "TUN mode on - routes the whole network (requires admin)" "OK"
        }
        else {
            Add-GuiLog "TUN mode off" "WARN"
        }
        Invoke-Background -OpScript $Script:tunToggleScript -OnComplete {
            Update-GuiStatus
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Connected (TUN $(if ($Script:GuiSync.TunEnabled) { 'ON' } else { 'OFF' }))" "OK"
            }
        }
    })

    $Script:GuiBtnKs.Add_Click({
        if (-not $Script:GuiSync.KillSwitch) {
            if (-not $Script:GuiSync.TunEnabled) {
                Add-GuiLog "Kill switch requires TUN mode (turn on TUN first)" "WARN"
                return
            }
            $Script:GuiSync.KillSwitch = $true
            Add-GuiLog "Kill switch ON: all traffic outside the tunnel will be blocked" "WARN"
        }
        else {
            $Script:GuiSync.KillSwitch = $false
            Add-GuiLog "Kill switch OFF" "WARN"
        }
        Update-KsButton
        if ($Script:GuiSync.ConnectedConfig) {
            Invoke-Background -OpScript $Script:tunToggleScript -OnComplete {
                Update-GuiStatus
                $Script:GuiSync.KsActive = Test-KillSwitchActive
                Update-KsButton
                if ($Script:GuiSync.KillSwitch -and -not $Script:GuiSync.KsActive) {
                    Add-GuiLog "Kill switch NOT applied - see the log (killswitch)" "ERROR"
                }
            }
        }
    })

    $Script:GuiBtnSplit.Add_Click({ Show-SplitDialog })

    $Script:GuiBtnSettings.Add_Click({
        try {
            Update-ProxyButton
            Update-TunButton
            Update-KsButton
            Update-SplitLabel
            # Owner aqui (janela principal ja visivel): em CenterOwner ela abre centrada nela.
            if (-not $Script:GuiSettings.Owner) { $Script:GuiSettings.Owner = $Script:GuiWindow }
            [void]$Script:GuiSettings.Show()
            [void]$Script:GuiSettings.Activate()
        }
        catch {
            Add-GuiLog "Failed to open settings: $_" "ERROR"
        }
    })

    $Script:GuiTxtSearch.Add_TextChanged({
        $Script:GuiLblSearchHint.Visibility = if ($Script:GuiTxtSearch.Text) { 'Collapsed' } else { 'Visible' }
        Populate-ServerList
    })

    $Script:GuiCbCountry.Add_SelectionChanged({
        if ($Script:CountryUpdating) { return }
        Populate-ServerList
    })

    $Script:GuiBtnSort.Add_Click({
        $Script:SortDesc = -not $Script:SortDesc
        $Script:GuiIcoSort.Text = if ($Script:SortDesc) { [char]0xE70D } else { [char]0xE70E }
        $msg = if ($Script:SortDesc) { "Sorted by latency: highest first" } else { "Sorted by latency: lowest first" }
        Add-GuiLog $msg "INFO"
        Populate-ServerList
    })

    $Script:GuiBtnInfoKs.Add_Click({
        [System.Windows.MessageBox]::Show(
            "Kill switch`n`nBlocks ALL Windows outbound traffic (firewall profiles) except xray, the local proxy and the tunnel interface. If the VPN drops, nothing leaks to the internet.`n`nTUN mode only. Requires admin (UAC). On disconnect the firewall is restored; if the app is killed, the next start restores it (UAC).",
            "Kill switch",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning)
    })

    $Script:GuiBtnInfoSplit.Add_Click({
        [System.Windows.MessageBox]::Show(
            "Split tunneling`n`nListed domains and IPs/CIDRs go DIRECT (outside the VPN). Use it for banks, games, sites that block VPNs or your local network.`n`nExamples: netflix.com / 10.0.0.0/8. TUN mode only; applies on reconnect.",
            "Split tunneling",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $Script:GuiBtnInfoProxy.Add_Click({
        [System.Windows.MessageBox]::Show(
            "System proxy`n`nConfigures the Windows HTTP proxy (HTTP and HTTPS leave via 127.0.0.1). Only apps that respect the system proxy go through the VPN (browser, Discord text/API).`n`nApps using UDP/WebRTC (Discord voice, games) IGNORE the proxy and go direct. To route everything, use TUN mode.",
            "System proxy",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $Script:GuiBtnInfoTun.Add_Click({
        [System.Windows.MessageBox]::Show(
            "TUN mode`n`nCreates a virtual network adapter and routes ALL system traffic through the VPN - including Discord voice (UDP/WebRTC), games and apps that ignore proxies.`n`nDifference: the system proxy only covers apps that respect it; TUN covers everything.`n`nRequires running as administrator.",
            "TUN mode",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $Script:GuiBtnCopyLog.Add_Click({
        try {
            $text = (@($Script:GuiLstLog.Items) | ForEach-Object { [string]$_.Content }) -join "`r`n"
            if (-not $text) { $text = [string]$Script:GuiLblLog.Text }
            [System.Windows.Clipboard]::SetText($text)
            $Script:GuiLblLog.Text = "Activity copied ($($Script:GuiLstLog.Items.Count) lines)"
        }
        catch {
            $Script:GuiLblLog.Text = "Copy failed: $($_.Exception.Message)"
        }
    })

    # Alt+F4 / fechar pelo Windows: esconde em vez de matar a conexao
    $Script:GuiWindow.Add_Closing({
        param($sender, $e)
        if (-not $Script:AllowClose) {
            $e.Cancel = $true
            if ($Script:GuiSettings) { $Script:GuiSettings.Hide() }
            $Script:GuiWindow.Hide()
            $Script:GuiWindow.ShowInTaskbar = $false
            if ($Script:TrayIcon) {
                $Script:TrayIcon.ShowBalloonTip(3000, "SETT VPN", "Still running in the tray. Use Exit in the tray menu to quit.", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    })

    $Script:GuiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:GuiTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $Script:GuiTimer.Add_Tick({
        # Segunda instancia: traz a janela de volta
        if ($Script:ActivateEvent -and $Script:ActivateEvent.WaitOne(0)) {
            Show-GuiWindow
        }

        # Progress bar
        if ($Script:GuiPbScan) {
            $p = [int]$Script:GuiSync.Progress
            $Script:GuiPbScan.Value = $p
            # Barra so ocupa espaco quando ha o que mostrar.
            $vis = if ($Script:GuiSync.State -eq "working") { 'Visible' } else { 'Collapsed' }
            $Script:GuiPbScan.Visibility = $vis
            if ($Script:GuiPnlProgress) { $Script:GuiPnlProgress.Visibility = $vis }
            if ($Script:GuiLblProgress) {
                $total = [int]$Script:GuiSync.ScanTotal
                if ($p -gt 0 -and $p -lt 100 -and $total -gt 0) {
                    $remaining = Get-ScanRemainingSeconds -Deadline $Script:GuiSync.ScanDeadline
                    $txt = "$p%"
                    if ($remaining -ge 60) {
                        $txt += " - ~$([int]($remaining/60))m$($remaining % 60)s left"
                    }
                    else {
                        $txt += " - ~${remaining}s left"
                    }
                    $Script:GuiLblProgress.Text = $txt
                }
                elseif ($p -ge 100) { $Script:GuiLblProgress.Text = "100%" }
                else { $Script:GuiLblProgress.Text = "" }
            }
        }

        # Estatisticas de trafego da sessao (runspace em loop, sem travar a UI)
        if ($Script:GuiSync.ConnectedConfig) {
            if (-not $Script:StatsHandle -and -not $Script:StatsSync.Running) { Start-GuiStats }
        }
        elseif ($Script:StatsSync.Running) { Stop-GuiStats }
        Complete-GuiStats
        if ($Script:GuiLblTraffic) {
            if ($Script:GuiSync.ConnectedConfig) {
                $Script:GuiLblTraffic.Text = "↓ $(Format-Bytes $Script:StatsSync.Down)   ↑ $(Format-Bytes $Script:StatsSync.Up)"
            }
            else {
                $Script:GuiLblTraffic.Text = "↓ 0 B   ↑ 0 B"
            }
        }

        if ($Script:GuiSync.State -eq "working") {
            $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
            if ($Script:GuiSync.Handle -and $Script:GuiSync.Handle.IsCompleted) {
                try { $Script:GuiSync.Worker.EndInvoke($Script:GuiSync.Handle) } catch { }
                if ($Script:GuiSync.Runspace) { try { $Script:GuiSync.Runspace.Dispose() } catch {} }
                if ($Script:GuiSync.Worker) { try { $Script:GuiSync.Worker.Dispose() } catch {} }
                $Script:GuiSync.Handle = $null
                $Script:GuiSync.Worker = $null
                $Script:GuiSync.Runspace = $null
                $Script:GuiSync.State = "done"
                Set-GuiBusy $false
                $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
                Update-GuiStatus
                if ($Script:GuiSync.OnComplete) { & $Script:GuiSync.OnComplete; $Script:GuiSync.OnComplete = $null }
            }
        }
    })
    $Script:GuiTimer.Start()

    # Health check: revalida o tunel a cada ~15s quando conectado
    $Script:HealthTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:HealthTimer.Interval = [TimeSpan]::FromSeconds(5)
    $Script:HealthTimer.Add_Tick({
        # Estado real do kill switch (o supervisor escreve/apaga o backup)
        $ksNow = Test-KillSwitchActive
        if ($ksNow -ne $Script:GuiSync.KsActive) {
            $Script:GuiSync.KsActive = $ksNow
            Update-KsButton
        }
        if ($Script:GuiLblKs) {
            if ($Script:GuiSync.KsActive) {
                $Script:GuiLblKs.Text = "ACTIVE - nothing leaks outside the tunnel"
                $Script:GuiLblKs.Foreground = $Script:BrushGreen
            }
            else {
                $Script:GuiLblKs.Text = "blocks everything outside the tunnel · TUN only"
                $Script:GuiLblKs.Foreground = $Script:BrushMuted
            }
        }

        if ($Script:HealthHandle -and $Script:HealthHandle.IsCompleted) {
            try { $Script:HealthPs.EndInvoke($Script:HealthHandle) } catch {}
            if ($Script:HealthRs) { try { $Script:HealthRs.Dispose() } catch {} }
            if ($Script:HealthPs) { try { $Script:HealthPs.Dispose() } catch {} }
            $Script:HealthHandle = $null
            $Script:HealthPs = $null
            $Script:HealthRs = $null

            if ($Script:HealthSync.Result -eq $false -and $Script:GuiSync.ConnectedConfig) {
                $dropped = $Script:GuiSync.ConnectedConfig
                $Script:BadServers["$($dropped.Host):$($dropped.Port)"] = [DateTime]::Now
                $Script:GuiSync.ConnectedConfig = $null
                $Script:GuiSync.ExitIp = ""
                Update-GuiStatus
                Add-GuiLog "TUNNEL DROPPED - reconnecting..." "ERROR"
                Show-GuiWindow
                Invoke-Background -OpScript $Script:reconnectScript -OnComplete {
                    Update-GuiStatus; Populate-ServerList
                    if ($Script:GuiSync.ConnectedConfig) {
                        Add-GuiLog "Reconnected: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
                    }
                    else {
                        Add-GuiLog "Reconnect failed" "ERROR"
                    }
                }
            }
        }

        if ($Script:GuiSync.ConnectedConfig -and -not $Script:HealthHandle -and ($Script:GuiSync.State -ne "working")) {
            if ([DateTime]::Now -ge $Script:LastHealthCheck.AddSeconds(15)) {
                $Script:LastHealthCheck = [DateTime]::Now
                $Script:HealthSync.Tun = [bool]$Script:GuiSync.TunEnabled
                Start-GuiHealthCheck
            }
        }
    })
    $Script:HealthTimer.Start()

    # Balão de aviso no início (deixa claro que o app ficou na bandeja)
    $Script:BalloonTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:BalloonTimer.Interval = [TimeSpan]::FromSeconds(1)
    $Script:BalloonTimer.Add_Tick({
        $Script:BalloonTimer.Stop()
        if ($Script:TrayIcon) {
            $Script:TrayIcon.ShowBalloonTip(4000, "SETT VPN", "Rodando na bandeja. Feche a janela para continuar em segundo plano.", [System.Windows.Forms.ToolTipIcon]::Info)
        }
        # Auto-refresh no start: lista pronta sem o usuario clicar
        $Script:GuiBtnChange.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    })
    $Script:BalloonTimer.Start()

    Update-GuiStatus
    Update-ProxyButton
    Update-TunButton
    Update-KsButton
    Update-SplitLabel
    Set-GuiBusy $false
    Add-GuiLog "Ready. Refresh the server list." "INFO"

    $Script:MainFrame = New-Object System.Windows.Threading.DispatcherFrame
    $Script:GuiWindow.Show()

    # Força o ícone nativo da janela (barra de tarefas) via WM_SETICON
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Script:GuiWindow)
        $hwnd = $helper.Handle
        if ($hwnd -ne [IntPtr]::Zero -and $Script:AppIcon) {
            [SettVPNNative]::SendMessage($hwnd, 0x80, [IntPtr]1, $Script:AppIcon.Handle) | Out-Null
            [SettVPNNative]::SendMessage($hwnd, 0x80, [IntPtr]0, $Script:AppIcon.Handle) | Out-Null
        }
    }
    catch { }

    [System.Windows.Threading.Dispatcher]::PushFrame($Script:MainFrame)

    if ($Script:GuiTimer) { $Script:GuiTimer.Stop() }
    if ($Script:HealthTimer) { $Script:HealthTimer.Stop() }
    if ($Script:TrayIcon) { try { $Script:TrayIcon.Visible = $false; $Script:TrayIcon.Dispose() } catch {} }
    if ($Script:AppIcon) { try { $Script:AppIcon.Dispose() } catch {} }
    Stop-V2Ray
    if ($Script:ProxyActive) { Disable-SystemProxy }
}
