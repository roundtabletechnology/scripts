<#
.SYNOPSIS
    Configures automatic logoff of idle users on shared Windows workstations.

.DESCRIPTION
    Creates a scheduled task (RTT - Shared Device Auto Logoff) that logs off the
    active console session after a configurable period of keyboard and mouse
    inactivity. Uses Windows Task Scheduler's built-in idle detection - no
    third-party tools required.

    The task runs as SYSTEM, fires on the IdleTrigger after the specified idle
    duration, and uses PowerShell to query active sessions (qwinsta) and log each
    off by session ID.
    It is persistent across reboots. Re-running the script replaces the existing
    task, which allows the timeout to be updated.

    Intended for shared laptops and workstations where sessions should not persist
    after a user walks away.

.PARAMETER IdleMinutes
    Minutes of inactivity before the user is logged off. Defaults to 10.
    Set to 0 to remove the scheduled task (reverses the configuration).
    Can also be set via Ninja environment variables (see NOTES).

.EXAMPLE
    .\Configure Auto Logoff.ps1

.EXAMPLE
    .\Configure Auto Logoff.ps1 -IdleMinutes 15

.EXAMPLE
    .\Configure Auto Logoff.ps1 -IdleMinutes 0
    Removes the 'RTT - Shared Device Auto Logoff' scheduled task.

.NOTES
    Deployed via NinjaOne RMM. Runs at SYSTEM level with no interactive UI.
    Run once per targeted device - the scheduled task persists across reboots.

    NinjaOne fields:
      minutesToAutoLogoff     (org, integer)   - idle timeout in minutes; read via Get-NinjaProperty
      autoLogoffInactiveUsers (device, checkbox) - uncheck to remove the task; read via Get-NinjaProperty
      idleLogoffMinutes       (script variable, integer) - legacy env var; superseded by minutesToAutoLogoff

    The task is named 'RTT - Shared Device Auto Logoff' in Task Scheduler.
    To remove it manually:
        Unregister-ScheduledTask -TaskName 'RTT - Shared Device Auto Logoff' -Confirm:$false

    See 0071363 for more details.
#>

#Requires -RunAsAdministrator

param(
    [int]$IdleMinutes = 10
)

$ProgressPreference = "SilentlyContinue"

#region Functions

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$ts] [$Level] $Message"
}

#endregion

# Legacy script variable override (env var explicitly mapped in the NinjaOne automation UI)
if ($env:idleLogoffMinutes) { $IdleMinutes = [int]$env:idleLogoffMinutes }

# Read org and device custom fields via the NinjaOne agent module.
# Get-NinjaProperty is loaded into the session by the NinjaOne agent. The PATH setup
# ensures the underlying ninjarmm-cli.exe is resolvable, using the agent env var if
# present or falling back to the known install path.
$ninjaCliDir = if ($env:NINJARMMCLI) { Split-Path $env:NINJARMMCLI -Parent } else { 'C:\ProgramData\NinjaRMMAgent' }
if ($env:Path -notlike "*$ninjaCliDir*") { $env:Path = "$ninjaCliDir;$env:Path" }

if (Get-Command Get-NinjaProperty -ErrorAction SilentlyContinue) {
    try {
        $v = Get-NinjaProperty -Name "minutesToAutoLogoff" -ErrorAction Stop
        if ($null -ne $v) {
            $IdleMinutes = [int]$v
            Write-Log "NinjaOne: minutesToAutoLogoff = $v"
        }
    } catch {
        Write-Log "Could not read 'minutesToAutoLogoff' from NinjaOne: $($_.Exception.Message)" "Warning"
    }

    # 0/"0"/$false/"false" = unchecked (remove task); null or throws = not configured, ignored
    # Get-NinjaProperty returns checkbox values as string "0"/"1", not boolean.
    try {
        $v = Get-NinjaProperty -Name "autoLogoffInactiveUsers" -ErrorAction Stop
        Write-Log "NinjaOne: autoLogoffInactiveUsers = $v"
        if ($v -eq $false -or $v -eq 'false' -or $v -eq '0') { $IdleMinutes = 0 }
    } catch {
        Write-Log "Could not read 'autoLogoffInactiveUsers' from NinjaOne: $($_.Exception.Message)" "Warning"
    }
} else {
    Write-Log "Get-NinjaProperty not available - custom field reads skipped (manual run or agent not installed)."
}

$TaskName = "RTT - Shared Device Auto Logoff"

try {
    Write-Log "=== Configure Auto Logoff Start ==="

    # Enable Task Scheduler operational logging if not already on. The log is capped
    # at 4 MB by default and wraps automatically - no meaningful storage impact.
    # This makes it possible to confirm task execution on customer machines.
    $tsLogConfig = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration "Microsoft-Windows-TaskScheduler/Operational"
    if (-not $tsLogConfig.IsEnabled) {
        $tsLogConfig.IsEnabled = $true
        $tsLogConfig.SaveChanges()
        Write-Log "Enabled Task Scheduler operational logging."
    }

    # IdleMinutes = 0 means remove the task and exit
    if ($IdleMinutes -eq 0) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed '$TaskName' scheduled task." "Success"
        } else {
            Write-Log "Task '$TaskName' not found - nothing to remove."
        }
        exit 0
    }

    Write-Log "Idle timeout: $IdleMinutes minutes"

    # Remove existing task to allow clean re-registration with updated settings
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Removed existing '$TaskName' task."
    }

    $idleDuration = "PT${IdleMinutes}M"

    # Task XML using IdleTrigger:
    #   - Fires after $IdleMinutes of system inactivity (no keyboard/mouse, CPU/disk
    #     below the OS idle threshold).
    #   - Runs as SYSTEM (S-1-5-18) so it can terminate any user session.
    #   - Uses qwinsta to find active sessions by ID and logs each off. This is
    #     more reliable than 'logoff console', which is not available on all
    #     Windows configurations. Sessions with no active user produce no output
    #     so the task silently succeeds at the login screen.
    #   - StopOnIdleEnd=true cancels the task if the user returns before it fires.
    #   - DisallowStartIfOnBatteries=false ensures logoff works on laptop battery.
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Logs off the active console session after $IdleMinutes minutes of inactivity. Managed by RTT.</Description>
  </RegistrationInfo>
  <Triggers>
    <IdleTrigger>
      <Enabled>true</Enabled>
    </IdleTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <RunOnlyIfIdle>true</RunOnlyIfIdle>
    <IdleSettings>
      <Duration>$idleDuration</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -NoProfile -WindowStyle Hidden -Command "qwinsta | Select-String 'Active' | ForEach-Object { if (`$_ -match '(\d+)\s+Active') { logoff `$matches[1] } }"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null

    Write-Log "Task '$TaskName' registered successfully." "Success"
    Write-Log "Users will be logged off after $IdleMinutes minutes of inactivity."

    exit 0

} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "Error"
    exit 1
}
