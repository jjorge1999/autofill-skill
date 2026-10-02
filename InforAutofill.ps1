<#
.SYNOPSIS
  InforAutofill window: status, this week, Preview / File now, schedule and settings.
.DESCRIPTION
  Front end only. Filing is done by Invoke-AutoFile.ps1 (also run by the 'InforAutofill-File' scheduled task);
  this window reads the presence log, hcm/overrides.json, run logs and state, and starts those scripts.
.PARAMETER SelfTest
  Build the window and the model, print 'selftest ok', exit. Shows nothing, starts nothing.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $here 'InforAutofill.ps1')`"")
    if ($SelfTest) { $a += '-SelfTest' }
    $p = Start-Process powershell.exe -ArgumentList $a -PassThru -Wait:$SelfTest -NoNewWindow:$SelfTest
    if ($SelfTest) { exit $p.ExitCode }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $here 'Presence.Common.ps1')
. (Join-Path $here 'AutoFile.Common.ps1')
. (Join-Path $here 'Dashboard.Data.ps1')

$configPath = Join-Path $here 'config.json'
$overridesPath = Join-Path $here 'hcm\overrides.json'
$readmePath = Join-Path $here 'README.md'
$fileTaskName = 'InforAutofill-File'
$inv = [Globalization.CultureInfo]::InvariantCulture
$check = [string][char]0x2713
$dash = [string][char]0x2013

# ---- theme (follows the Windows app light/dark setting)
$light = $true
try {
    $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    $light = ($v -ne 0)
} catch { $light = $true }
$theme = if ($light) {
    @{ Bg = '#F6F6F7'; Card = '#FFFFFF'; Text = '#1C1C1F'; Muted = '#6E6E76'; Border = '#E5E5E9'; Accent = '#2563EB'; Amber = '#B45309'; Chip = '#F1F1F4' }
} else {
    @{ Bg = '#161618'; Card = '#202024'; Text = '#F2F2F4'; Muted = '#9B9BA4'; Border = '#2D2D33'; Accent = '#60A5FA'; Amber = '#FBBF24'; Chip = '#2A2A30' }
}
function Format-Xaml([string]$x) { foreach ($k in $theme.Keys) { $x = $x.Replace("{$k}", $theme[$k]) }; return $x }
function Get-Brush([string]$hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

$xaml = Format-Xaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="InforAutofill" Width="440" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="{Bg}" Foreground="{Text}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{Card}"/>
      <Setter Property="BorderBrush" Value="{Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Muted}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{Text}"/>
      <Setter Property="Background" Value="{Card}"/>
      <Setter Property="BorderBrush" Value="{Border}"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{Accent}"/>
      <Setter Property="BorderBrush" Value="{Accent}"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="20,18,20,20">
    <Grid Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="InforAutofill" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="NextRun" Style="{StaticResource Muted}" Margin="0,2,0,0"/>
      </StackPanel>
      <Button x:Name="ScheduleBtn" Grid.Column="1" Style="{StaticResource Btn}" Margin="0,0,8,0" VerticalAlignment="Center"
              ToolTip="Turns the scheduled presence checks and filing on or off"/>
      <Button x:Name="SettingsBtn" Grid.Column="2" Style="{StaticResource Btn}" Padding="10,9" VerticalAlignment="Center"
              FontFamily="Segoe MDL2 Assets" Content="&#xE713;" ToolTip="Settings"/>
    </Grid>

    <Border Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock x:Name="TodayLabel" Style="{StaticResource Muted}"/>
        <Grid Margin="0,4,0,0">
          <TextBlock x:Name="TodayStatus" FontSize="28" FontWeight="SemiBold"/>
          <TextBlock x:Name="LastCheck" Style="{StaticResource Muted}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,6"/>
        </Grid>
      </StackPanel>
    </Border>

    <Border Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="This week" Style="{StaticResource Muted}"/>
        <UniformGrid x:Name="Days" Columns="5" Margin="-3,10,-3,0"/>
        <TextBlock x:Name="XmLine" Margin="0,14,0,0"/>
        <TextBlock x:Name="Hint" Style="{StaticResource Muted}" Margin="0,4,0,0" TextWrapping="Wrap"
                   Text="Click a day to mark it WFH, Office or Leave."/>
      </StackPanel>
    </Border>

    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Button x:Name="PreviewBtn" Style="{StaticResource Btn}" Content="Preview" ToolTip="Show what a run would do; files nothing"/>
      <Button x:Name="FileBtn" Grid.Column="2" Style="{StaticResource Primary}" Content="File now" ToolTip="Run the same filing the scheduled task does"/>
    </Grid>

    <Expander x:Name="LogExpander" Header="Log" Margin="0,14,0,0" Foreground="{Muted}">
      <TextBox x:Name="LogBox" Height="190" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="NoWrap"
               FontFamily="Cascadia Mono, Consolas" FontSize="11" Padding="8"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    </Expander>
  </StackPanel>
</Window>
'@

$settingsXaml = Format-Xaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="340" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{Bg}" Foreground="{Text}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <StackPanel Margin="20">
    <TextBlock Text="Filing time (HH:mm)" Foreground="{Muted}" FontSize="12"/>
    <TextBox x:Name="TimeBox" Margin="0,6,0,0" Padding="6" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    <TextBlock Foreground="{Muted}" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"
               Text="Today is only filed at or after this time, once the day's network checks are in."/>
    <TextBlock x:Name="TimeError" Foreground="{Amber}" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <Button x:Name="SaveBtn" Content="Save" Margin="0,12,0,0" Padding="12,8" Background="{Accent}" Foreground="White" BorderBrush="{Accent}"/>
    <Separator Margin="0,16" Background="{Border}"/>
    <Button x:Name="LogsBtn" Content="Open log folder" Padding="12,8" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    <Button x:Name="ReadmeBtn" Content="Open README" Margin="0,8,0,0" Padding="12,8" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
  </StackPanel>
</Window>
'@

function New-WpfWindow([string]$x) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$x)
    return [Windows.Markup.XamlReader]::Load($reader)
}

$win = New-WpfWindow $xaml
$ui = @{}
foreach ($n in 'NextRun', 'ScheduleBtn', 'SettingsBtn', 'TodayLabel', 'TodayStatus', 'LastCheck', 'Days', 'XmLine', 'Hint', 'PreviewBtn', 'FileBtn', 'LogExpander', 'LogBox') {
    $ui[$n] = $win.FindName($n)
}

# ---- data
function Get-DataDir {
    $cfg = Get-InforConfig -Path $configPath
    return Split-Path -Parent (Resolve-LogPath $cfg.log_path)
}

function Get-FileTask { return Get-ScheduledTask -TaskName $fileTaskName -ErrorAction SilentlyContinue }

function Get-Model {
    $today = (Get-Date).Date
    $week = Get-WeekDates -Today $today
    $dataDir = Get-DataDir
    $summary = @()
    try { $summary = @(& (Join-Path $here 'Get-DailySummary.ps1') -From $week[0] -To $week[-1] -ConfigPath $configPath 3>$null) } catch { $summary = @() }
    $overrides = Read-JsonMap -Path $overridesPath
    $hcmFiled = Get-HcmFiledDates -Logs @(Read-RunLogs -Dir (Join-Path $here 'hcm\logs'))
    $state = $null
    $statePath = Join-Path $dataDir 'autofile-state.json'
    if (Test-Path -LiteralPath $statePath) { try { $state = Read-AutoFileState -Path $statePath -Today $today } catch { $state = $null } }
    $weekStart = ConvertTo-IsoDate $week[0].AddDays(-1)
    $xm = Get-XmWeekStatus -Logs @(Read-RunLogs -Dir (Join-Path $here 'xm\logs')) -WeekStart $weekStart -State $state
    $last = Get-LastReadingTime -PresencePath (Join-Path $dataDir 'presence.csv') -Date $today
    return New-DashboardModel -Today $today -WeekDates $week -Summary $summary -Overrides $overrides -HcmFiled $hcmFiled -Xm $xm -LastReading $last
}

function Get-StatusText([string]$s) {
    switch ($s) { 'wfh' { 'WFH' } 'office' { 'Office' } 'leave' { 'Leave' } 'weekend' { 'Weekend' } default { '?' } }
}
function Get-StatusBrush([string]$s) {
    switch ($s) { 'wfh' { Get-Brush $theme.Accent } 'leave' { Get-Brush $theme.Amber } 'office' { Get-Brush $theme.Text } default { Get-Brush $theme.Muted } }
}

function New-DayChip($day) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $win.FindResource('Btn')
    $b.Margin = '3'
    $b.Padding = '4,10'
    $b.Background = Get-Brush $theme.Chip
    $b.BorderBrush = Get-Brush $(if ($day.IsToday) { $theme.Accent } else { $theme.Chip })
    $b.Tag = $day.Date
    $sp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $day.DayName
    $t1.FontSize = 11
    $t1.Foreground = Get-Brush $theme.Muted
    $t1.HorizontalAlignment = 'Center'
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = Get-StatusText $day.Status
    $t2.FontWeight = 'SemiBold'
    $t2.Margin = '0,4,0,0'
    $t2.Foreground = Get-StatusBrush $day.Status
    $t2.HorizontalAlignment = 'Center'
    $t3 = New-Object System.Windows.Controls.TextBlock
    $t3.Text = $(if ($day.HcmFiled) { "$check HCM" } else { $dash })
    $t3.FontSize = 11
    $t3.Margin = '0,4,0,0'
    $t3.Foreground = Get-Brush $theme.Muted
    $t3.HorizontalAlignment = 'Center'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($t3)
    $b.Content = $sp
    $tip = "$($day.Date): $(Get-StatusText $day.Status)"
    if ($day.Source -eq 'override') { $tip += ' (marked by you)' }
    if ($day.Note) { $tip += " - $($day.Note)" }
    $b.ToolTip = $tip

    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($pair in @(@('WFH', 'wfh'), @('Office', 'office'), @('Leave', 'leave'), @('Clear', 'clear'))) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $pair[0]
        $mi.Tag = "$($day.Date)|$($pair[1])"
        $mi.Add_Click({
            param($sender, $e)
            $parts = ([string]$sender.Tag).Split('|')
            $saveError = $null
            try { Set-DayOverride -Path $overridesPath -Date $parts[0] -Value $parts[1] } catch { $saveError = $_.Exception.Message }
            Invoke-Safe { Update-View }
            if ($saveError) { $ui.Hint.Text = "Could not save: $saveError" }
        })
        [void]$menu.Items.Add($mi)
    }
    $b.ContextMenu = $menu
    $b.Add_Click({ param($sender, $e) $sender.ContextMenu.PlacementTarget = $sender; $sender.ContextMenu.IsOpen = $true })
    return $b
}

function Update-View {
    try {
        $m = Get-Model
    } catch {
        $ui.TodayStatus.Text = '?'
        $ui.Hint.Text = "No data yet: $($_.Exception.Message)"
        return
    }
    $ui.TodayLabel.Text = $m.TodayLabel
    $ui.TodayStatus.Text = Get-StatusText $m.TodayStatus
    $ui.TodayStatus.Foreground = Get-StatusBrush $m.TodayStatus
    $ui.LastCheck.Text = $(if ($m.LastReading) { "last check $($m.LastReading)" } else { 'no check yet today' })
    $ui.Days.Children.Clear()
    foreach ($d in $m.Days) { [void]$ui.Days.Children.Add((New-DayChip $d)) }
    $ui.XmLine.Text = "XM  $($m.Xm.Text)"
    $ui.Hint.Text = 'Click a day to mark it WFH, Office or Leave. An office reading always wins over WFH; file leave in HCM yourself.'

    try {
        $task = Get-FileTask
        if ($task) {
            $ui.ScheduleBtn.Content = 'On'
            $ui.ScheduleBtn.Foreground = Get-Brush $theme.Accent
            $next = $null
            try { $next = ($task | Get-ScheduledTaskInfo -ErrorAction Stop).NextRunTime } catch { $next = $null }
            if ($next) { $ui.NextRun.Text = 'Next run  ' + $next.ToString('ddd d MMM, HH:mm', $inv) }
            else { $ui.NextRun.Text = 'Next run  -' }
        } else {
            $ui.ScheduleBtn.Content = 'Off'
            $ui.ScheduleBtn.Foreground = Get-Brush $theme.Muted
            $ui.NextRun.Text = 'Automatic filing is off'
        }
    } catch {
        $ui.NextRun.Text = "Schedule unknown: $($_.Exception.Message)"
    }
}

# Event handlers must never take the window down: report the error quietly instead.
function Invoke-Safe([scriptblock]$Body) {
    try { & $Body } catch { $ui.Hint.Text = "Something went wrong: $($_.Exception.Message)" }
}

function ConvertTo-Quoted([string]$Path) {
    # Single-quoted literal for a -Command string.
    return "'" + $Path.Replace("'", "''") + "'"
}

# ---- child processes (never Start-Process -WindowStyle Hidden: it can close the question dialog)
function Start-Child([string]$CommandText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$CommandText`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $here
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-SharedText([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object IO.StreamReader($fs, $true); return $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

$script:Run = $null
$runTimer = New-Object System.Windows.Threading.DispatcherTimer
$runTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$runTimer.Add_Tick({ Invoke-Safe {
    if (-not $script:Run) { $runTimer.Stop(); return }
    $text = Read-SharedText $script:Run.Out
    if ($text) { $ui.LogBox.Text = $text; $ui.LogBox.ScrollToEnd() }
    if ($script:Run.Proc.HasExited) {
        $runTimer.Stop()
        $ui.LogBox.Text = (Read-SharedText $script:Run.Out) + "`r`n(exit $($script:Run.Proc.ExitCode))"
        $ui.LogBox.ScrollToEnd()
        Remove-Item -LiteralPath $script:Run.Out -ErrorAction SilentlyContinue
        $script:Run = $null
        $ui.PreviewBtn.IsEnabled = $true; $ui.FileBtn.IsEnabled = $true; $ui.ScheduleBtn.IsEnabled = $true
        Update-View
    }
} })

function Start-AutoFile([switch]$Preview) {
    if ($script:Run) { return }
    $out = Join-Path ([IO.Path]::GetTempPath()) ("inforautofill-ui-{0}.log" -f [guid]::NewGuid())
    $flag = ''
    if ($Preview) { $flag = ' -WhatIf' }
    $cmd = "& {0}{1} *> {2}" -f (ConvertTo-Quoted (Join-Path $here 'Invoke-AutoFile.ps1')), $flag, (ConvertTo-Quoted $out)
    $ui.PreviewBtn.IsEnabled = $false; $ui.FileBtn.IsEnabled = $false; $ui.ScheduleBtn.IsEnabled = $false
    $ui.LogExpander.IsExpanded = $true
    $ui.LogBox.Text = $(if ($Preview) { 'Preview running...' } else { 'Filing running... (Edge may open if Infor needs you to sign in)' })
    try { $proc = Start-Child $cmd }
    catch {
        $ui.PreviewBtn.IsEnabled = $true; $ui.FileBtn.IsEnabled = $true; $ui.ScheduleBtn.IsEnabled = $true
        $ui.LogBox.Text = "Could not start the run: $($_.Exception.Message)"
        return
    }
    $script:Run = @{ Proc = $proc; Out = $out }
    $runTimer.Start()
}

function Invoke-Scheduler([switch]$Uninstall) {
    $flag = ''
    if ($Uninstall) { $flag = ' -Uninstall' }
    $p = Start-Child ("& {0}{1}" -f (ConvertTo-Quoted (Join-Path $here 'Install-Scheduler.ps1')), $flag)
    if (-not $p.WaitForExit(60000)) { throw 'Install-Scheduler.ps1 did not finish within 60 s.' }
    if ($p.ExitCode -ne 0) { throw "Install-Scheduler.ps1 failed (exit $($p.ExitCode)). Run it in a PowerShell window to see why." }
}

$ui.PreviewBtn.Add_Click({ Invoke-Safe { Start-AutoFile -Preview } })
$ui.FileBtn.Add_Click({ Invoke-Safe {
    $r = [System.Windows.MessageBox]::Show($win, 'Run the filing now? It submits WFH days to HCM and, when due, the XM timesheet - the same as the scheduled run.', 'InforAutofill', 'OKCancel', 'Question')
    if ($r -eq 'OK') { Start-AutoFile }
} })
$ui.ScheduleBtn.Add_Click({ Invoke-Safe {
    $on = [bool](Get-FileTask)
    $msg = $(if ($on) { 'Turn automatic filing off? This removes both scheduled tasks (presence checks and filing).' } else { 'Turn automatic filing on? This registers the presence checks and the filing task for your user.' })
    $r = [System.Windows.MessageBox]::Show($win, $msg, 'InforAutofill', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }
    $win.Cursor = 'Wait'
    $schedError = $null
    try { if ($on) { Invoke-Scheduler -Uninstall } else { Invoke-Scheduler } } catch { $schedError = $_.Exception.Message } finally { $win.Cursor = $null }
    Update-View
    if ($schedError) { $ui.Hint.Text = $schedError }
} })
$ui.SettingsBtn.Add_Click({ Invoke-Safe {
    $sw = New-WpfWindow $settingsXaml
    $sw.Owner = $win
    $tb = $sw.FindName('TimeBox')
    $err = $sw.FindName('TimeError')
    $cfg = Get-InforConfig -Path $configPath
    $tb.Text = $(if ($cfg.PSObject.Properties.Name -contains 'file_time' -and $cfg.file_time) { [string]$cfg.file_time } else { '16:30' })
    $sw.FindName('SaveBtn').Add_Click({
        $t = $tb.Text.Trim()
        if (-not (Test-FileTime $t)) { $err.Text = 'Use HH:mm, for example 16:30.'; return }
        try {
            Set-ConfigFileTime -ConfigPath $configPath -Time $t
            if (Get-FileTask) { Invoke-Scheduler }
            $sw.Close()
            Update-View
        } catch { $err.Text = $_.Exception.Message }
    })
    $sw.FindName('LogsBtn').Add_Click({ try { Start-Process explorer.exe -ArgumentList "`"$(Get-DataDir)`"" } catch { $err.Text = $_.Exception.Message } })
    $sw.FindName('ReadmeBtn').Add_Click({ try { Start-Process notepad.exe -ArgumentList "`"$readmePath`"" } catch { $err.Text = $_.Exception.Message } })
    [void]$sw.ShowDialog()
} })

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(60)
$refreshTimer.Add_Tick({ Invoke-Safe { if (-not $script:Run) { Update-View } } })

Update-View
if ($SelfTest) {
    $win.Close()
    Write-Output 'selftest ok'
    exit 0
}
$refreshTimer.Start()
[void]$win.ShowDialog()
