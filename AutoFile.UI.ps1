# Interactive pieces of Invoke-AutoFile.ps1 (needs the logged-on user's desktop). Windows PowerShell 5.1.
# Dot-source this file; it has no side effects.

function Show-DayQuestion {
    # One row per date with WFH / Office / Leave. Returns @{date = 'wfh'|'office'|'leave'} for answered rows.
    # Closes by itself after -TimeoutMinutes as "Ask me later" (no answers), so an unattended run never blocks.
    param([Parameter(Mandatory = $true)][string[]]$Dates, [double]$TimeoutMinutes = 15)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'InforAutofill - where were you?'
    $form.TopMost = $true
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.AutoSize = $true
    $form.AutoSizeMode = 'GrowAndShrink'

    $stack = New-Object System.Windows.Forms.FlowLayoutPanel
    $stack.FlowDirection = 'TopDown'
    $stack.AutoSize = $true
    $stack.Padding = New-Object System.Windows.Forms.Padding(12)
    $form.Controls.Add($stack)

    $intro = New-Object System.Windows.Forms.Label
    $intro.AutoSize = $true
    $intro.MaximumSize = New-Object System.Drawing.Size(420, 0)
    $mins = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMinutes))
    $intro.Text = "No network reading for these workdays, so HCM was not filed. Pick one per day. Unanswered days are asked again next time.`r`n`r`n" +
        "Leave: XM counts the day as 8 h leave, but nothing is filed in HCM - file the leave in HCM yourself.`r`n`r`n" +
        "This window closes by itself after $mins minute$(if ($mins -ne 1) { 's' }) (same as 'Ask me later')."
    $stack.Controls.Add($intro)

    $radios = @()
    foreach ($d in $Dates) {
        $row = New-Object System.Windows.Forms.FlowLayoutPanel   # its own container = its own radio group
        $row.AutoSize = $true
        $row.WrapContents = $false
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Width = 130
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.Text = ([datetime]::ParseExact($d, 'yyyy-MM-dd', $inv)).ToString('ddd d MMM yyyy', $inv)
        $row.Controls.Add($lbl)
        foreach ($choice in 'WFH', 'Office', 'Leave') {
            $rb = New-Object System.Windows.Forms.RadioButton
            $rb.Text = $choice
            $rb.AutoSize = $true
            $rb.Tag = "$d|$($choice.ToLowerInvariant())"
            $row.Controls.Add($rb)
            $radios += $rb
        }
        $stack.Controls.Add($row)
    }

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true
    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $later = New-Object System.Windows.Forms.Button
    $later.Text = 'Ask me later'
    $later.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttons.Controls.Add($save)
    $buttons.Controls.Add($later)
    $stack.Controls.Add($buttons)
    $form.AcceptButton = $save
    $form.CancelButton = $later

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int][Math]::Max(1000, [Math]::Min([int]::MaxValue, $TimeoutMinutes * 60000))
    $timer.Tag = $form
    $timer.add_Tick({
            param($sender, $e)
            $sender.Stop()
            $sender.Tag.DialogResult = [System.Windows.Forms.DialogResult]::Cancel   # closes the modal form
        })

    $answers = @{}
    $timer.Start()   # ticks once ShowDialog runs the message loop
    $result = $form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($rb in $radios) {
            if ($rb.Checked) { $parts = ([string]$rb.Tag).Split('|'); $answers[$parts[0]] = $parts[1] }
        }
    }
    $form.Dispose()
    return $answers
}

function Show-AutoFileNotification {
    # Windows notification (tray balloon, shown as a toast on Windows 10/11). Blocks ~6 s so it is not torn down early.
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$Text, [switch]$IsError)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = if ($IsError) { [System.Drawing.SystemIcons]::Warning } else { [System.Drawing.SystemIcons]::Information }
    $n.Visible = $true
    $tip = if ($IsError) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 247) + '...' }
    $n.ShowBalloonTip(10000, $Title, $Text, $tip)
    Start-Sleep -Seconds 6
    $n.Dispose()
}
