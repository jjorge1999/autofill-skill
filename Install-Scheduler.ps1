<#
.SYNOPSIS
  Registers (or removes) the 'InforAutofill-PresenceCheck' and 'InforAutofill-File' scheduled tasks for the current user.
.DESCRIPTION
  InforAutofill-PresenceCheck: one weekly trigger per check_time on the configured workdays, plus an at-logon trigger.
  InforAutofill-File: runs Invoke-AutoFile.ps1 (HCM Telecommuting for WFH days, XM weekly timesheet) on the
  workdays at file_time and 2 minutes after logon.
  Both run only while you are logged on, hidden, no admin rights needed.
.EXAMPLE
  .\Install-Scheduler.ps1
  .\Install-Scheduler.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Presence.Common.ps1')

$taskName = 'InforAutofill-PresenceCheck'
$fileTaskName = 'InforAutofill-File'

if ($Uninstall) {
    foreach ($n in $taskName, $fileTaskName) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false
            Write-Host "Removed scheduled task '$n'."
        } else {
            Write-Host "Scheduled task '$n' is not installed."
        }
    }
    return
}

$config = Get-InforConfig -Path $ConfigPath
$dayMap = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
$days = @()
foreach ($w in @($config.workdays)) {
    if (-not $dayMap.ContainsKey($w)) { throw "Invalid workday '$w' in config.json (use Mon, Tue, Wed, Thu, Fri, Sat, Sun)" }
    $days += $dayMap[$w]
}
if ($days.Count -eq 0) { throw 'config.json workdays is empty.' }

$detectScript = Join-Path $PSScriptRoot 'Detect-Presence.ps1'
$userId = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$detectScript`"" `
    -WorkingDirectory $PSScriptRoot

$triggers = @()
foreach ($t in @($config.check_times)) {
    $at = [datetime]::ParseExact($t, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $triggers += New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $days -At $at
}
$triggers += New-ScheduledTaskTrigger -AtLogOn -User $userId

$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal `
    -Settings $settings -Description 'Logs office/WFH presence based on the connected network (InforAutofill).' -Force | Out-Null

Write-Host "Registered '$taskName' for $userId"
Write-Host ("  Times: " + (@($config.check_times) -join ', ') + " on " + (@($config.workdays) -join ', ') + ", plus at logon")
Write-Host "  Script: $detectScript"

$fileTime = if ($config.PSObject.Properties.Name -contains 'file_time' -and $config.file_time) { [string]$config.file_time } else { '16:30' }
$fileAt = [datetime]::ParseExact($fileTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$fileScript = Join-Path $PSScriptRoot 'Invoke-AutoFile.ps1'
$fileAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$fileScript`"" `
    -WorkingDirectory $PSScriptRoot
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$logonTrigger.Delay = 'PT2M'   # let the network come up first
$fileTriggers = @(
    (New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $days -At $fileAt),
    $logonTrigger
)
$fileSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $fileTaskName -Action $fileAction -Trigger $fileTriggers -Principal $principal `
    -Settings $fileSettings -Description 'Files HCM Telecommuting (WFH days) and the XM weekly timesheet (InforAutofill).' -Force | Out-Null

Write-Host "Registered '$fileTaskName' for $userId"
Write-Host ("  Time: $fileTime on " + (@($config.workdays) -join ', ') + ", plus 2 min after logon")
Write-Host "  Script: $fileScript"
