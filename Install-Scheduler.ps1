<#
.SYNOPSIS
  Registers (or removes) the 'InforAutofill-PresenceCheck' scheduled task for the current user.
.DESCRIPTION
  One weekly trigger per check_time on the configured workdays, plus an at-logon trigger.
  Runs only while you are logged on, hidden, no admin rights needed.
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

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'."
    } else {
        Write-Host "Scheduled task '$taskName' is not installed."
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
