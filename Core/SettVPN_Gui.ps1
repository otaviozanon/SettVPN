# ============================================================
# SettVPN - GUI (WPF)
# Deve ser dot-sourced pelo SettVPN_Full.ps1
# ============================================================

$Script:GuiFuncSource = $null

$Script:GuiSync = [hashtable]::Synchronized(@{
    State           = "idle"
    StatusText      = "Pronto"
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
`$Sync = `$GuiSyncRef
`$BadServers = `$BadServersRef
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
    $Script:GuiBtnFilter.IsEnabled = -not $Busy
    $Script:GuiBtnDisconnect.IsEnabled = -not $Busy
    $Script:GuiBtnConnectSelected.IsEnabled = (-not $Busy) -and $Script:ListReady
}

function Update-GuiStatus {
    $cfg = $Script:GuiSync.ConnectedConfig
    if ($cfg) {
        $Script:GuiLblStatus.Text = "CONECTADO"
        $Script:GuiLblStatus.Foreground = $Script:BrushGreen
        $Script:GuiDotStatus.Fill = $Script:BrushGreen
        $srvLabel = [string]$cfg.Name
        $country = [string]$cfg['Country']
        if ($country) { $srvLabel += "  ($country)" }
        $Script:GuiLblServer.Text = $srvLabel
        $Script:GuiLblPing.Text = "Ping: $($cfg.Ping)ms  |  $($cfg.Protocol)  |  $($cfg.Host):$($cfg.Port)"
    }
    else {
        $Script:GuiLblStatus.Text = "DESCONECTADO"
        $Script:GuiLblStatus.Foreground = $Script:BrushRed
        $Script:GuiDotStatus.Fill = $Script:BrushRed
        $Script:GuiLblServer.Text = "Sem conexao"
        $Script:GuiLblPing.Text = "Conecte para ocultar seu IP"
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

function Populate-ServerList {
    $Script:GuiLstServers.Items.Clear()
    $style = $Script:GuiWindow.FindResource("ServerItemStyle")
    if ($Script:GuiSync.Servers.Count -eq 0) {
        $ph = New-Object System.Windows.Controls.ListBoxItem
        $ph.Style = $style
        $ph.Content = "Nenhum servidor - clique em ATUALIZAR SERVIDORES"
        $ph.Foreground = $Script:BrushMuted
        $ph.FontSize = 12
        $ph.IsEnabled = $false
        $ph.Opacity = 0.6
        [void]$Script:GuiLstServers.Items.Add($ph)
        $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
        return
    }
    foreach ($cfg in $Script:GuiSync.Servers) {
        $ping = [int]$cfg.Ping
        if ($ping -lt 100) { $color = $Script:BrushGreen }
        elseif ($ping -lt 300) { $color = $Script:BrushGold }
        else { $color = $Script:BrushRed }

        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Style = $style
        $item.Foreground = $color
        $label = ("{0,4} ms   {1}" -f $ping, [string]$cfg.Name)
        $country = [string]$cfg['Country']
        if ($country) { $label += "  ($country)" }
        $item.Content = $label
        $item.FontSize = 12
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

        $code = $Script:GuiFuncSource + "`n" + @'
Set-StrictMode -Version Latest
$sync = $HealthSyncRef
$sync.Result = Test-V2RayTunnel
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

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SETT VPN"
        Width="820" Height="590"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="#0A0A0C"
        BorderBrush="#2A2A30"
        BorderThickness="1"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style x:Key="CloseBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A8A94"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" Width="{TemplateBinding Width}" Height="{TemplateBinding Height}">
              <TextBlock Text="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#DA3633"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MinBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A8A94"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" Width="{TemplateBinding Width}" Height="{TemplateBinding Height}">
              <TextBlock Text="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A30"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
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
      <RowDefinition Height="32"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" x:Name="titleBar" Background="#141417" BorderBrush="#2A2A30" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="&#9889;" Foreground="#D4AF37" FontSize="13" VerticalAlignment="Center"/>
          <TextBlock Text="SETT VPN" Foreground="#EDEDEF" FontSize="12" FontWeight="SemiBold" Margin="7,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Border Grid.Column="2"><Button x:Name="btnMin" Content="_" Style="{StaticResource MinBtn}"/></Border>
        <Border Grid.Column="3"><Button x:Name="btnClose" Content="X" Style="{StaticResource CloseBtn}"/></Border>
      </Grid>
    </Border>

    <Grid Grid.Row="1" Margin="24,20,24,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="22"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0">
        <Border Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="8" Padding="16,16">
          <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <Ellipse x:Name="dotStatus" Width="9" Height="9" Fill="#DA3633" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="lblStatus" Text="DESCONECTADO" FontSize="15" FontWeight="SemiBold" Foreground="#DA3633" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="lblServer" Text="Sem conexao" FontSize="13" Foreground="#C5C5CC" HorizontalAlignment="Center" Margin="0,10,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="lblPing" Text="Conecte para ocultar seu IP" FontSize="11" Foreground="#8A8A94" HorizontalAlignment="Center" Margin="0,3,0,0"/>
          </StackPanel>
        </Border>

        <Button x:Name="btnConnect" Content="CONECTAR (MENOR PING)" Height="42" Margin="0,16,0,0" Style="{StaticResource PrimaryBtn}"/>

        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="btnChange" Grid.Column="0" Content="ATUALIZAR" Height="34" Style="{StaticResource GhostBtn}"/>
          <Button x:Name="btnFilter" Grid.Column="2" Content="FILTRAR" Height="34" Style="{StaticResource GhostBtn}"/>
          <Button x:Name="btnDisconnect" Grid.Column="4" Content="DESCONECTAR" Height="34" Style="{StaticResource GhostBtn}"/>
        </Grid>

        <Grid Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Proxy do sistema" Foreground="#C5C5CC" FontSize="12" VerticalAlignment="Center"/>
              <Button x:Name="btnInfoProxy" Style="{StaticResource InfoBtn}" ToolTip="Clique para detalhes"/>
            </StackPanel>
            <TextBlock Text="SOCKS5 :10808  ·  HTTP :10809" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
          </StackPanel>
          <Button x:Name="btnProxy" Grid.Column="1" Content="OFF" Width="62" Height="30" Style="{StaticResource GhostBtn}"/>
        </Grid>

        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Modo TUN (toda rede)" Foreground="#C5C5CC" FontSize="12" VerticalAlignment="Center"/>
              <Button x:Name="btnInfoTun" Style="{StaticResource InfoBtn}" ToolTip="Clique para detalhes"/>
            </StackPanel>
            <TextBlock Text="Roteia Discord/voz · requer admin" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
          </StackPanel>
          <Button x:Name="btnTun" Grid.Column="1" Content="OFF" Width="62" Height="30" Style="{StaticResource GhostBtn}"/>
        </Grid>

        <Border Background="#141417" BorderBrush="#2A2A30" BorderThickness="1" CornerRadius="8" Padding="10,8" Margin="0,16,0,0">
          <StackPanel>
            <TextBlock Text="ATIVIDADE" FontSize="10" FontWeight="SemiBold" Foreground="#8A8A94" Margin="0,0,0,6"/>
            <ListBox x:Name="lstLog" Background="Transparent" Foreground="#8A8A94" BorderThickness="0" FontSize="10" Height="70"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled" IsHitTestVisible="False" Focusable="False"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <TextBlock Text="PROGRESSO" FontSize="10" FontWeight="SemiBold" Foreground="#8A8A94"/>
              <TextBlock x:Name="lblProgress" Text="" FontSize="10" Foreground="#D4AF37" Margin="8,0,0,0"/>
            </StackPanel>
            <ProgressBar x:Name="pbScan" Height="6" Margin="0,5,0,0" Background="#1E1E22" Foreground="#D4AF37" BorderThickness="0" Minimum="0" Maximum="100" Value="0"/>
          </StackPanel>
        </Border>
      </StackPanel>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="SERVIDORES" FontSize="10" FontWeight="SemiBold" Foreground="#8A8A94" Margin="2,0,0,8"/>
        <ListBox x:Name="lstServers" Grid.Row="1" Background="#141417" Foreground="#C5C5CC" BorderBrush="#2A2A30" BorderThickness="1" FontSize="12" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ItemContainerStyle="{StaticResource ServerItemStyle}"/>
        <Button x:Name="btnConnectSelected" Grid.Row="2" Content="CONECTAR NO SELECIONADO" Height="34" Margin="0,8,0,0" Style="{StaticResource GhostBtn}"/>
      </Grid>
    </Grid>

    <Border Grid.Row="2" BorderBrush="#2A2A30" BorderThickness="0,1,0,0" Background="#141417" Padding="24,10,24,10">
      <TextBlock x:Name="lblLog" Text="Pronto" Foreground="#8A8A94" FontSize="11" TextWrapping="Wrap"/>
    </Border>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $Script:GuiWindow = [Windows.Markup.XamlReader]::Load($reader)

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
    $Script:GuiLblLog           = $Script:GuiWindow.FindName("lblLog")
    $Script:GuiLstServers       = $Script:GuiWindow.FindName("lstServers")
    $Script:GuiLstLog           = $Script:GuiWindow.FindName("lstLog")
    $Script:GuiPbScan           = $Script:GuiWindow.FindName("pbScan")
    $Script:GuiLblProgress      = $Script:GuiWindow.FindName("lblProgress")
    $Script:GuiBtnProxy         = $Script:GuiWindow.FindName("btnProxy")
    $Script:GuiBtnTun           = $Script:GuiWindow.FindName("btnTun")
    $Script:GuiBtnInfoProxy     = $Script:GuiWindow.FindName("btnInfoProxy")
    $Script:GuiBtnInfoTun       = $Script:GuiWindow.FindName("btnInfoTun")
    $Script:GuiBtnConnect       = $Script:GuiWindow.FindName("btnConnect")
    $Script:GuiBtnChange        = $Script:GuiWindow.FindName("btnChange")
    $Script:GuiBtnFilter        = $Script:GuiWindow.FindName("btnFilter")
    $Script:GuiBtnDisconnect    = $Script:GuiWindow.FindName("btnDisconnect")
    $Script:GuiBtnConnectSelected = $Script:GuiWindow.FindName("btnConnectSelected")
    $btnClose          = $Script:GuiWindow.FindName("btnClose")
    $btnMin            = $Script:GuiWindow.FindName("btnMin")
    $titleBar          = $Script:GuiWindow.FindName("titleBar")

    # Tray icon: fecha janela -> continua rodando na bandeja
    $Script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $Script:TrayIcon.Text = "SETT VPN"
    if ($Script:AppIcon) {
        $Script:TrayIcon.Icon = $Script:AppIcon
    }
    $Script:TrayIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $menuOpen = New-Object System.Windows.Forms.ToolStripMenuItem "Abrir"
    $menuExit = New-Object System.Windows.Forms.ToolStripMenuItem "Sair"
    $menuOpen.Add_Click({
        Show-GuiWindow
    })
    $menuExit.Add_Click({
        try { $Script:GuiWindow.Close() } catch {}
        if ($Script:MainFrame) { $Script:MainFrame.Continue = $false }
    })
    [void]$trayMenu.Items.Add($menuOpen)
    [void]$trayMenu.Items.Add($menuExit)
    $Script:TrayIcon.ContextMenuStrip = $trayMenu
    $Script:TrayIcon.Add_DoubleClick({
        Show-GuiWindow
    })

    # Health check state
    $Script:HealthSync = [hashtable]::Synchronized(@{ Busy = $false; Result = $null })
    $Script:HealthHandle = $null
    $Script:HealthPs = $null
    $Script:HealthRs = $null
    $Script:LastHealthCheck = [DateTime]::MinValue
    $Script:BadServers = [hashtable]::Synchronized(@{})
    $Script:ListReady = $false

    $Script:connectScript = @'
if (-not $Sync.Servers -or $Sync.Servers.Count -eq 0) { $Sync.StatusText = "Atualize a lista primeiro"; return }
foreach ($cfg in $Sync.Servers) {
    $Sync.StatusText = "Conectando: $(Get-ShortName $cfg.Name)"
    if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $(Get-ShortName $cfg.Name)"; return }
}
$Sync.ConnectedConfig = $null
$Sync.StatusText = "Falha ao conectar nos servidores listados"
'@

    $Script:reconnectScript = @'
# Prioriza os servidores ja validados como estaveis (pool atual)
$now = [DateTime]::Now
$pool = @($Sync.Servers | Where-Object { $k = "$($_.Host):$($_.Port)"; -not ($BadServers.ContainsKey($k) -and (($now - $BadServers[$k]).TotalMinutes -lt 5)) })
$pool = @($pool | Sort-Object -Property @{ Expression = { [int]$_.Ping } })
if ($pool.Count -gt 0) {
    foreach ($cfg in $pool) {
        $Sync.StatusText = "Tentando: $(Get-ShortName $cfg.Name) ($($cfg.Ping)ms)"
        if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $(Get-ShortName $cfg.Name)"; return }
    }
}

# Fallback: pool esgotado -> refaz do mesmo modo (filtrado ou nao)
$Sync.StatusText = "Pool esgotado - refazendo..."
$candidates = Get-ServerPool -Filtered $Sync.Filtered -BadServers $BadServers
if (-not $candidates -or $candidates.Count -eq 0) { $Sync.ConnectedConfig = $null; $Sync.StatusText = "Nenhum servidor encontrado"; return }
$Sync.Servers = $candidates
foreach ($cfg in $candidates) {
    $Sync.StatusText = "Tentando: $(Get-ShortName $cfg.Name) ($($cfg.Ping)ms)"
    if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $(Get-ShortName $cfg.Name)"; return }
}
$Sync.ConnectedConfig = $null
$Sync.StatusText = "Falhou em todos os servidores"
'@

    $Script:refreshScript = @'
$pool = Get-ServerPool -BadServers $BadServers
if (-not $pool -or $pool.Count -eq 0) { $Sync.Servers = @(); $Sync.StatusText = "Nenhum servidor encontrado"; return }
$Sync.Servers = $pool
$Sync.Filtered = $false
$Sync.StatusText = "Encontrados $($pool.Count) servidores (sem filtro)"
'@

    $Script:filterScript = @'
$pool = Get-ServerPool -Filtered $true -BadServers $BadServers
$Sync.Filtered = $true
if (-not $pool -or $pool.Count -eq 0) { $Sync.Servers = @(); $Sync.StatusText = "Nenhum servidor estavel"; return }
$Sync.Servers = $pool
$Sync.StatusText = "Estaveis: $($pool.Count)"
'@

    $Script:connectSelectedScript = @'
$idx = $Sync.SelectedIndex
if ($idx -lt 0 -or $idx -ge $Sync.Servers.Count) { $Sync.StatusText = "Nenhum servidor selecionado"; return }
$cfg = $Sync.Servers[$idx]
$Sync.StatusText = "Conectando: $(Get-ShortName $cfg.Name)"
if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $(Get-ShortName $cfg.Name)" }
else { $Sync.ConnectedConfig = $null; $Sync.StatusText = "Falha ao conectar em $(Get-ShortName $cfg.Name)" }
'@

    $Script:tunToggleScript = @'
$cfg = $Sync.ConnectedConfig
if (-not $cfg) {
    $Sync.StatusText = if ($Sync.TunEnabled) { "Modo TUN ativado (aplica ao conectar)" } else { "Modo TUN desativado" }
    return
}
$Sync.StatusText = if ($Sync.TunEnabled) { "Reconectando com TUN..." } else { "Reconectando sem TUN..." }
if (Start-V2Ray -Config $cfg -Tun:([bool]$Sync.TunEnabled)) {
    $Sync.ConnectedConfig = $cfg
    $Sync.StatusText = if ($Sync.TunEnabled) { "Conectado (TUN ON)" } else { "Conectado (TUN OFF)" }
}
else {
    $Sync.ConnectedConfig = $null
    $Sync.StatusText = "Falha ao reconectar com modo TUN"
}
'@

    $Script:GuiBtnConnect.Add_Click({
        $Script:GuiLblLog.Text = "Conectando..."
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "Proxy do sistema desativado" "WARN" }
        Add-GuiLog "Conectando (menor ping)..." "INFO"
        Invoke-Background -OpScript $Script:connectScript -OnComplete {
            Update-GuiStatus; Populate-ServerList
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Conectado: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
            }
            else {
                Add-GuiLog "Falha ao conectar" "ERROR"
            }
        }
    })

    $Script:GuiBtnChange.Add_Click({
        $Script:GuiLblLog.Text = "Atualizando servidores..."
        Add-GuiLog "Atualizando servidores (sem teste)..." "INFO"
        Invoke-Background -OpScript $Script:refreshScript -OnComplete {
            Populate-ServerList
            $Script:ListReady = $true
            Set-GuiBusy $false
            Add-GuiLog "$($Script:GuiSync.Servers.Count) servidores encontrados" "OK"
        }
    })

    $Script:GuiBtnFilter.Add_Click({
        $Script:GuiLblLog.Text = "Filtrando servidores..."
        $Script:GuiSync.Progress = 0
        $Script:GuiSync.ScanTotal = 0
        $Script:GuiSync.ScanTested = 0
        $Script:GuiSync.ScanStart = [DateTime]::MinValue
        $Script:GuiSync.ScanDeadline = [DateTime]::MinValue
        Add-GuiLog "Filtrando (teste de estabilidade)..." "INFO"
        Invoke-Background -OpScript $Script:filterScript -OnComplete {
            Populate-ServerList
            $Script:ListReady = $true
            Set-GuiBusy $false
            Add-GuiLog "$($Script:GuiSync.Servers.Count) servidores estaveis" "OK"
        }
    })

    $Script:GuiBtnConnectSelected.Add_Click({
        $idx = $Script:GuiLstServers.SelectedIndex
        if ($idx -lt 0) { $Script:GuiLblLog.Text = "Selecione um servidor na lista"; return }
        $Script:GuiSync.SelectedIndex = $idx
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "Proxy do sistema desativado" "WARN" }
        Add-GuiLog "Conectando: $($Script:GuiSync.Servers[$idx].Name)" "INFO"
        Invoke-Background -OpScript $Script:connectSelectedScript -OnComplete {
            Update-GuiStatus
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Conectado: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
            }
            else {
                Add-GuiLog "Falha ao conectar" "ERROR"
            }
        }
    })

    $Script:GuiBtnDisconnect.Add_Click({
        if ($Script:ProxyActive) { Disable-SystemProxy; Update-ProxyButton; Add-GuiLog "Proxy do sistema desativado" "WARN" }
        if ($Script:GuiSync.TunEnabled) { $Script:GuiSync.TunEnabled = $false; Update-TunButton; Add-GuiLog "Modo TUN desativado" "WARN" }
        Stop-V2Ray
        $Script:GuiSync.ConnectedConfig = $null
        Update-GuiStatus
        $Script:GuiLblLog.Text = "Desconectado"
        Add-GuiLog "Desconectado" "WARN"
    })

    $Script:GuiBtnProxy.Add_Click({
        if ($Script:ProxyActive) {
            Disable-SystemProxy
            Update-ProxyButton
            Add-GuiLog "Proxy do sistema desativado" "WARN"
        }
        else {
            if ($Script:GuiSync.TunEnabled) {
                $Script:GuiSync.TunEnabled = $false
                Update-TunButton
                Add-GuiLog "Modo TUN desativado (proxy ativo)" "WARN"
            }
            Enable-SystemProxy
            Update-ProxyButton
            Add-GuiLog "Proxy do sistema ativado (HTTP 10809 / SOCKS5 10808)" "OK"
            Add-GuiLog "Voz do Discord (UDP) ignora proxy - use o modo TUN" "WARN"
            if ($Script:GuiSync.ConnectedConfig) {
                Invoke-Background -OpScript $Script:tunToggleScript -OnComplete { Update-GuiStatus }
            }
        }
    })

    $Script:GuiBtnTun.Add_Click({
        $Script:GuiSync.TunEnabled = -not $Script:GuiSync.TunEnabled
        Update-TunButton
        if ($Script:GuiSync.TunEnabled) {
            if ($Script:ProxyActive) {
                Disable-SystemProxy
                Update-ProxyButton
                Add-GuiLog "Proxy desativado (TUN cobre toda a rede)" "WARN"
            }
            Add-GuiLog "Modo TUN ativado - roteia toda a rede (requer admin)" "OK"
        }
        else {
            Add-GuiLog "Modo TUN desativado" "WARN"
        }
        Invoke-Background -OpScript $Script:tunToggleScript -OnComplete {
            Update-GuiStatus
            if ($Script:GuiSync.ConnectedConfig) {
                Add-GuiLog "Conectado (TUN $(if ($Script:GuiSync.TunEnabled) { 'ON' } else { 'OFF' }))" "OK"
            }
        }
    })

    $Script:GuiBtnInfoProxy.Add_Click({
        [System.Windows.MessageBox]::Show(
            "Proxy do sistema`n`nConfigura o proxy HTTP/SOCKS do Windows. Só os apps que respeitam o proxy do sistema passam pela VPN (navegador, Discord texto/API).`n`nApps que usam UDP/WebRTC (voz do Discord, jogos) IGNORAM o proxy e vão direto. Para rotear tudo, use o Modo TUN.",
            "Proxy do sistema",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $Script:GuiBtnInfoTun.Add_Click({
        [System.Windows.MessageBox]::Show(
            "Modo TUN`n`nCria um adaptador de rede virtual e roteia TODO o tráfego do sistema pela VPN — incluindo voz do Discord (UDP/WebRTC), jogos e apps que ignoram proxy.`n`nDiferença: o Proxy do sistema só pega apps que respeitam proxy; o TUN pega tudo.`n`nRequer executar como administrador.",
            "Modo TUN",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    })

    $btnClose.Add_Click({
        $Script:GuiWindow.Hide()
        $Script:GuiWindow.ShowInTaskbar = $false
        $Script:TrayIcon.ShowBalloonTip(3000, "SETT VPN", "Continua rodando na bandeja. A conexao permanece ativa.", [System.Windows.Forms.ToolTipIcon]::Info)
    })

    $btnMin.Add_Click({
        $Script:GuiWindow.WindowState = 'Minimized'
    })

    $titleBar.Add_MouseLeftButtonDown({
        if ($_[0].LeftButton -eq 'Pressed') {
            try { $Script:GuiWindow.DragMove() } catch { }
        }
    })

    $Script:GuiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:GuiTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $Script:GuiTimer.Add_Tick({
        # Progress bar
        if ($Script:GuiPbScan) {
            $p = [int]$Script:GuiSync.Progress
            $Script:GuiPbScan.Value = $p
            if ($Script:GuiLblProgress) {
                $total = [int]$Script:GuiSync.ScanTotal
                if ($p -gt 0 -and $p -lt 100 -and $total -gt 0) {
                    $remaining = Get-ScanRemainingSeconds -Deadline $Script:GuiSync.ScanDeadline
                    $txt = "$p%"
                    if ($remaining -ge 60) {
                        $txt += " - restante ~$([int]($remaining/60))m$($remaining % 60)s"
                    }
                    else {
                        $txt += " - restante ~${remaining}s"
                    }
                    $Script:GuiLblProgress.Text = $txt
                }
                elseif ($p -ge 100) { $Script:GuiLblProgress.Text = "100%" }
                else { $Script:GuiLblProgress.Text = "" }
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
                Update-GuiStatus
                Add-GuiLog "TUNEL CAIU - reconectando..." "ERROR"
                Show-GuiWindow
                Invoke-Background -OpScript $Script:reconnectScript -OnComplete {
                    Update-GuiStatus; Populate-ServerList
                    if ($Script:GuiSync.ConnectedConfig) {
                        Add-GuiLog "Reconectado: $($Script:GuiSync.ConnectedConfig.Name)" "OK"
                    }
                    else {
                        Add-GuiLog "Falha ao reconectar" "ERROR"
                    }
                }
            }
        }

        if ($Script:GuiSync.ConnectedConfig -and -not $Script:HealthHandle -and ($Script:GuiSync.State -ne "working")) {
            if ([DateTime]::Now -ge $Script:LastHealthCheck.AddSeconds(15)) {
                $Script:LastHealthCheck = [DateTime]::Now
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
    })
    $Script:BalloonTimer.Start()

    Update-GuiStatus
    Update-ProxyButton
    Update-TunButton
    Set-GuiBusy $false
    Add-GuiLog "Pronto. Atualize os servidores." "INFO"

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
