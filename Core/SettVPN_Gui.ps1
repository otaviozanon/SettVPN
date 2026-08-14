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

    $worker = [powershell]::Create()
    $worker.Runspace = $rs

    $setup = @"
`$Script:TempDir = '$($Script:TempDir)'
`$Script:V2RayExe = '$($Script:V2RayExe)'
`$Script:ConfigJson = '$($Script:ConfigJson)'
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
    $Script:GuiBtnConnect.IsEnabled = -not $Busy
    $Script:GuiBtnChange.IsEnabled = -not $Busy
    $Script:GuiBtnDisconnect.IsEnabled = -not $Busy
    $Script:GuiBtnConnectSelected.IsEnabled = -not $Busy
}

function Update-GuiStatus {
    $cfg = $Script:GuiSync.ConnectedConfig
    if ($cfg) {
        $Script:GuiLblStatus.Text = "CONECTADO"
        $Script:GuiLblStatus.Foreground = $Script:BrushGreen
        $Script:GuiDotStatus.Fill = $Script:BrushGreen
        $Script:GuiLblServer.Text = [string]$cfg.Name
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
        $item.Content = ("{0,4} ms   {1}" -f $ping, [string]$cfg.Name)
        $item.FontSize = 12
        [void]$Script:GuiLstServers.Items.Add($item)
    }
    $Script:GuiLblLog.Text = $Script:GuiSync.StatusText
}

function Start-SettVPN-Gui {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

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
        Width="820" Height="520"
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
            <ColumnDefinition Width="8"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="btnChange" Grid.Column="0" Content="ATUALIZAR" Height="34" Style="{StaticResource GhostBtn}"/>
          <Button x:Name="btnDisconnect" Grid.Column="2" Content="DESCONECTAR" Height="34" Style="{StaticResource GhostBtn}"/>
        </Grid>

        <Grid Margin="0,16,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Proxy do sistema" Foreground="#C5C5CC" FontSize="12"/>
            <TextBlock Text="SOCKS5 - 127.0.0.1:10808" Foreground="#8A8A94" FontSize="10" Margin="0,1,0,0"/>
          </StackPanel>
          <Button x:Name="btnProxy" Grid.Column="1" Content="OFF" Width="62" Height="30" Style="{StaticResource GhostBtn}"/>
        </Grid>
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

    try {
        $ico = Join-Path $Script:ScriptDir "settvpn.ico"
        if (Test-Path $ico) {
            $fs = [System.IO.File]::OpenRead($ico)
            $Script:GuiWindow.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($fs, [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $fs.Dispose()
        }
    }
    catch { }

    $Script:GuiLblStatus        = $Script:GuiWindow.FindName("lblStatus")
    $Script:GuiDotStatus        = $Script:GuiWindow.FindName("dotStatus")
    $Script:GuiLblServer        = $Script:GuiWindow.FindName("lblServer")
    $Script:GuiLblPing          = $Script:GuiWindow.FindName("lblPing")
    $Script:GuiLblLog           = $Script:GuiWindow.FindName("lblLog")
    $Script:GuiLstServers       = $Script:GuiWindow.FindName("lstServers")
    $Script:GuiBtnProxy         = $Script:GuiWindow.FindName("btnProxy")
    $Script:GuiBtnConnect       = $Script:GuiWindow.FindName("btnConnect")
    $Script:GuiBtnChange        = $Script:GuiWindow.FindName("btnChange")
    $Script:GuiBtnDisconnect    = $Script:GuiWindow.FindName("btnDisconnect")
    $Script:GuiBtnConnectSelected = $Script:GuiWindow.FindName("btnConnectSelected")
    $btnClose          = $Script:GuiWindow.FindName("btnClose")
    $btnMin            = $Script:GuiWindow.FindName("btnMin")
    $titleBar          = $Script:GuiWindow.FindName("titleBar")

    $connectScript = @'
$all = Get-AllConfigs
if (-not $all -or $all.Count -eq 0) { $Sync.StatusText = "Nenhum servidor encontrado"; return }
$sorted = Get-ConfigsWithPing -Configs $all
$Sync.Servers = @($sorted)
if (-not $sorted -or $sorted.Count -eq 0) { $Sync.StatusText = "Nenhum servidor alcancavel"; return }
foreach ($cfg in $sorted) {
    $Sync.StatusText = "Tentando: $($cfg.Name) ($($cfg.Ping)ms)"
    if (Start-V2Ray -Config $cfg) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $($cfg.Name)"; return }
}
$Sync.ConnectedConfig = $null
$Sync.StatusText = "Falhou em todos os servidores"
'@

    $refreshScript = @'
$all = Get-AllConfigs
if (-not $all -or $all.Count -eq 0) { $Sync.Servers = @(); $Sync.StatusText = "Nenhum servidor encontrado"; return }
$sorted = Get-ConfigsWithPing -Configs $all
$Sync.Servers = @($sorted)
$Sync.StatusText = "Encontrados $($sorted.Count) servidores"
'@

    $connectSelectedScript = @'
$idx = $Sync.SelectedIndex
if ($idx -lt 0 -or $idx -ge $Sync.Servers.Count) { $Sync.StatusText = "Nenhum servidor selecionado"; return }
$cfg = $Sync.Servers[$idx]
$Sync.StatusText = "Conectando: $($cfg.Name)"
if (Start-V2Ray -Config $cfg) { $Sync.ConnectedConfig = $cfg; $Sync.StatusText = "Conectado: $($cfg.Name)" }
else { $Sync.ConnectedConfig = $null; $Sync.StatusText = "Falha ao conectar em $($cfg.Name)" }
'@

    $Script:GuiBtnConnect.Add_Click({
        $Script:GuiLblLog.Text = "Carregando servidores..."
        Invoke-Background -OpScript $connectScript -OnComplete { Update-GuiStatus; Populate-ServerList }
    })

    $Script:GuiBtnChange.Add_Click({
        $Script:GuiLblLog.Text = "Atualizando servidores..."
        Invoke-Background -OpScript $refreshScript -OnComplete { Populate-ServerList }
    })

    $Script:GuiBtnConnectSelected.Add_Click({
        $idx = $Script:GuiLstServers.SelectedIndex
        if ($idx -lt 0) { $Script:GuiLblLog.Text = "Selecione um servidor na lista"; return }
        $Script:GuiSync.SelectedIndex = $idx
        Invoke-Background -OpScript $connectSelectedScript -OnComplete { Update-GuiStatus }
    })

    $Script:GuiBtnDisconnect.Add_Click({
        Stop-V2Ray
        $Script:GuiSync.ConnectedConfig = $null
        Update-GuiStatus
        $Script:GuiLblLog.Text = "Desconectado"
    })

    $Script:GuiBtnProxy.Add_Click({
        Toggle-SystemProxy
        Update-ProxyButton
    })

    $btnClose.Add_Click({
        $Script:GuiTimer.Stop()
        Stop-V2Ray
        if ($Script:ProxyActive) { Disable-SystemProxy }
        $Script:GuiWindow.Close()
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

    Update-GuiStatus
    Update-ProxyButton

    $Script:GuiWindow.ShowDialog() | Out-Null

    if ($Script:GuiTimer) { $Script:GuiTimer.Stop() }
    Stop-V2Ray
    if ($Script:ProxyActive) { Disable-SystemProxy }
}
