<#
.SYNOPSIS
    Removes the incumbent NinjaOne agent and installs the new MSP's NinjaOne agent.

.DESCRIPTION
    Designed for MSP-to-MSP customer fleet transfers. Fully removes the incumbent
    NinjaOne agent and all associated components (services, Ninja Remote, registry
    entries, drivers), then silently installs the new MSP's NinjaOne agent from
    the provided MSI installer URL.

    NinjaOne agents cannot install over an existing NinjaOne agent, so the incumbent
    must be removed first. Because removing the agent tears down the process tree that
    a NinjaOne script runs inside, the install cannot happen inline - it is handed to a
    Scheduled Task that runs outside this script's process tree. NinjaOne's own GPO
    deployment tooling uses the same pattern, gated on service absence.

    WHY A SCHEDULED TASK, WHEN UPSTREAM REMOVED THEIRS:
    The community script this one descends from (see .NOTES) dropped its scheduled task
    on 2025-12-30 after several users reported the reinstall "working on some systems and
    not on others" - the same symptom that prompted this rewrite. That was never
    diagnosed upstream. The cause is almost certainly that both upstream task versions
    called New-ScheduledTask with NO -Settings argument, inheriting the Task Scheduler
    defaults: DisallowStartIfOnBatteries and StopIfGoingOnBatteries are True and
    StartWhenAvailable is False. A desktop installs, a laptop on battery never does, and
    a trigger missed while the device was asleep is dropped instead of run late. So the
    task is kept here and every one of those settings is now set explicitly (see
    Register-InstallTask) - it is the only design that survives a reboot and retries.

    Upstream's replacement is to write the work to a .ps1, launch it with a detached
    Start-Process (no -Wait), and exit immediately so no live process tree remains to be
    killed. That is faster (removal starts in ~1 minute rather than 5) but has no retry
    at all: if the child dies or the device reboots, nothing tries again.

    KNOWN LIMITATION: the removal below still runs inline in this process, which is the
    one the agent teardown can kill. If that happens partway through Uninstall-NinjaMSI,
    the cleanup after it is skipped and the install task will take its "agent gone, no
    signal" branch and install over a partially-cleaned machine. Moving the removal into
    the task alongside the install would close this; it is a deliberate open item.

    Order of operations - the machine is never left without a path to an agent:
      1. Download and rigorously validate the MSI. Nothing is touched until this passes.
      2. Write the install helper and register the Scheduled Task (with retries).
      3. Remove the incumbent agent.
      4. Signal removal completion so the task can proceed immediately.

    Installer URL precedence (highest to lowest):
      1. Ninja script variable "installerUrl"  ($env:installerUrl)
      2. -InstallerURL parameter
      3. $NewMSPInstallerURL hardcoded in this script

.PARAMETER InstallerURL
    Full HTTPS URL to the new MSP's NinjaOne MSI installer for the target organization.
    Obtain from: New MSP NinjaOne > Administration > Installer > Windows Agent > Generate Installer.
    Select the correct customer organization before generating.

.PARAMETER InstallDelayMinutes
    Minutes to wait before the install task first fires. Default 5. The task does not
    rely on this delay being long enough - it waits for the removal to signal completion
    (see -MaxRemovalWaitMinutes) and retries on a schedule regardless.

.PARAMETER MaxRemovalWaitMinutes
    How long the install task waits for removal to finish before installing anyway.
    Default 30. It also proceeds early once the incumbent agent has actually gone, so
    this ceiling only applies if this script is killed before it can signal completion.

.PARAMETER RetryWindowHours
    How long the install task keeps retrying if the install fails. Default 4.

.PARAMETER DryRun
    Validate the installer URL, report what would be removed, and exit without changing
    anything. Use this to confirm the URL and survey a machine before committing.

.EXAMPLE
    .\Reinstall NinjaRMM Agent.ps1

    Runs using the URL set in $NewMSPInstallerURL or the Ninja script variable.

.EXAMPLE
    .\Reinstall NinjaRMM Agent.ps1 -InstallerURL 'https://app.ninjarmm.com/agent/installer/...'

.EXAMPLE
    .\Reinstall NinjaRMM Agent.ps1 -DryRun

    Reports what would happen - validates the download and lists the detected agent -
    without removing or installing anything.

.NOTES
    --- OPTION 1: Direct execution (simplest for a single transfer) ---
    Fill in $NewMSPInstallerURL below with the MSI URL and deploy the script as-is.
    The partner MSP can run it directly or add it to their NinjaOne without any
    additional configuration.

    --- OPTION 2: Ninja Script Variable (flexible, reusable across orgs) ---
    1. Add this script in the partner NinjaOne: Scripting > Scripts > Add Script.
    2. In the script editor, add a Script Variable:
         - Type:  String
         - Name:  installerUrl
         - Label: NinjaRMM Installer URL
    3. When running or scheduling the script, paste the MSI URL into the variable field.

    The installer URL is available from:
      New MSP NinjaOne > Administration > Installer > Windows Agent > Generate Installer
    Be sure to select the correct customer organization before generating the URL.

    --- PREFERRED ALTERNATIVE: ask the incumbent MSP to delete the device ---
    Per NinjaOne's own Removal Guide, deleting a device from the NinjaOne console
    triggers a silent uninstall that succeeds even when Uninstall Prevention is ON.
    That is the supported path. This script is the fallback for when the incumbent
    will not cooperate, the device is offline in their console, or the agent is corrupt.

    --- TROUBLESHOOTING A FAILED TRANSFER ---
    Everything is logged to a durable location that survives the agent removal:
      C:\ProgramData\RTT\NinjaAgentTransfer\transfer.log   (this script)
      C:\ProgramData\RTT\NinjaAgentTransfer\install.log    (the install task)
      C:\ProgramData\RTT\NinjaAgentTransfer\msi-install.log
    That folder also holds the MSI and the install helper. It is deliberately NOT
    cleaned up on failure so a failed machine can be diagnosed after the fact.

    --- CANCELING THE INSTALL TASK ---
    Unregister-ScheduledTask -TaskName 'NinjaRMM-NewAgentInstall' -Confirm:$false

    --- REFERENCES ---
    NinjaOne Agent Removal (official custom script)
      https://www.ninjaone.com/docs/scripting-and-automation/custom-scripts/remove-endpoint-agent-windows-custom-script/
    NinjaOne Agent Uninstall Prevention
      https://www.ninjaone.com/docs/new-to-ninjaone/agent-installation/agent-uninstall-prevention/
    NinjaOne agent deployment via GPO scheduled task (gates on service absence)
      https://www.ninjaone.com/docs/new-to-ninjaone/agent-installation/gpo-scheduled-task/
    NinjaOne Endpoint Management: Agent Removal Guide (portal login required)
      https://ninjarmm.zendesk.com/hc/en-us/articles/115001836286
    Reinstall or Migrate NinjaOne Agent - the origin of this script, by Mark Giordano
    (NinjaOne). Dojo > Community > Community Scripting; portal login required. Its
    comment thread is where the scheduled-task failures were reported and where the
    older task-based versions can still be read.
#>

# NOTE: '#Requires -RunAsAdministrator' is deliberately NOT used. It is a PowerShell 4.0
# feature and causes a confusing PARSE-TIME failure on PowerShell 3.0, which can still be
# found on a neglected server. The check is done at runtime below instead, so an
# under-privileged run produces a clear message rather than a syntax error.

param (
    [string]$InstallerURL,
    [int]$InstallDelayMinutes   = 5,
    [int]$MaxRemovalWaitMinutes = 30,
    [int]$RetryWindowHours      = 4,
    [switch]$DryRun
)

# ==============================================================================
# CONFIGURATION - Paste the new MSP's NinjaOne agent installer URL here.
# See .NOTES above for how to obtain the URL and Ninja script variable setup.
# ==============================================================================
$NewMSPInstallerURL = ''
# ==============================================================================

$ScriptVersion = '2.0.1'
$TaskName      = 'NinjaRMM-NewAgentInstall'

# Identifies the agent itself, as opposed to other Ninja-branded products that can share
# the machine (a real device carried "NinjaRMM Desktop Companion x64" alongside two
# NinjaRMMAgent registrations). Only the agent is uninstalled, and only the agent's
# Windows Installer records are scrubbed - deleting another product's installer records
# while leaving it installed would break its servicing and uninstall.
$AgentNamePattern = '^NinjaRMMAgent$|NinjaOne\s*Agent|^NinjaRMM\s*Agent$'

# $ProgressPreference is not cosmetic on Windows PowerShell 5.1: the progress bar is
# redrawn per read-chunk and can make a download 5-50x slower, and it is worst in exactly
# the non-interactive host an RMM uses. A slow transfer has more time to hit a proxy or
# idle timeout, so this materially affects reliability, not just tidiness.
$ProgressPreference = 'SilentlyContinue'

# Fail fast during preflight, download and task registration - nothing has been destroyed
# yet, so a hard stop is the safe outcome. This is deliberately relaxed to 'Continue'
# later, once removal begins and best-effort cleanup becomes the right behaviour.
$ErrorActionPreference = 'Stop'

# --- Durable state directory ---
# Must live outside every path the removal deletes (notably $env:ProgramData\NinjaRMMAgent)
# so the MSI, the install helper and the logs all survive the agent teardown.
$StateDir        = Join-Path $env:ProgramData 'RTT\NinjaAgentTransfer'
$LogFile         = Join-Path $StateDir 'transfer.log'
$MsiPath         = Join-Path $StateDir 'NinjaAgentInstall.msi'
$HelperPs1       = Join-Path $StateDir 'Install-NinjaAgent.ps1'
$RemovalDoneFlag = Join-Path $StateDir 'removal.done'
$InstallDoneFlag = Join-Path $StateDir 'install.done'

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

# Writes a timestamped, leveled line to the console AND to a durable log file. NinjaOne
# captures console output as the script activity log, but that log dies with the agent - so
# the file copy is the only record that survives a failed transfer.
#
# Write-Host, NOT Write-Output. This is load-bearing, not stylistic: Write-Output writes to
# the SUCCESS PIPELINE, so calling it from inside a function that returns a value silently
# prepends every log line to that return value. A validation function ending in
# 'return $false' would then hand its caller @('log line', ..., $false) - a non-empty
# array, which PowerShell evaluates as $true. That turns 'if (-not (Test-InstallerFile ...))'
# into a no-op and lets a corrupt installer through the exact gate meant to catch it.
# Write-Host bypasses the pipeline while still reaching the console (and therefore Ninja).
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

# Returns the real System32 for the current process. A 32-bit process on 64-bit Windows
# has System32 file-system-redirected to SysWOW64, and some tools (notably pnputil.exe)
# do not exist there. The NinjaOne agent is a 32-bit application, so a Ninja-launched
# script can plausibly be running 32-bit - in which case calling 'pnputil' fails with
# "not recognized" and driver cleanup is skipped without anyone noticing.
function Get-NativeSystem32 {
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return (Join-Path $env:SystemRoot 'Sysnative')
    }
    return (Join-Path $env:SystemRoot 'System32')
}

# ==============================================================================
# DOWNLOAD AND VALIDATION
# ==============================================================================

# Enables TLS 1.2 additively, using numeric literals.
#
# Two deliberate choices here:
#   - Numeric (3072/768) rather than [Net.SecurityProtocolType]::Tls12, because that enum
#     member does not exist on .NET Framework 4.0 and referencing it throws outright.
#   - '-bor' onto the existing value rather than assignment, because plain assignment of
#     Tls12 REPLACES the whole set and thereby DISABLES TLS 1.3 on modern machines. On
#     .NET 4.7+ the default is SystemDefault, which is better than anything hardcoded here.
function Enable-ModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 768
    } catch {
        try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch {
            Write-Log 'Could not raise the TLS version; relying on OS defaults.' -Level Warning
        }
    }
}

# Reads the system (WinINET) proxy for the current user, if one is configured.
# curl.exe does NOT read the Windows proxy configuration - it only honours the
# http_proxy/https_proxy environment variables or an explicit -x. On a corporate fleet
# that makes curl useless behind a proxy unless the proxy is passed in explicitly.
function Get-SystemProxy {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $p   = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p -and $p.ProxyEnable -eq 1 -and $p.ProxyServer) { return [string]$p.ProxyServer }
    } catch { }
    return $null
}

# Asks the server how big the file is, so the download can be checked for truncation.
# This is the most important validation input: Windows PowerShell 5.1 carries a known,
# unfixed bug (PowerShell/PowerShell#17931) where a mid-transfer connection loss leaves a
# PARTIAL FILE ON DISK and returns exit code 0 with no exception. On 5.1 the absence of an
# error is therefore not evidence of a complete download - only a byte-count match is.
# Returns 0 if the server will not say, in which case the check is skipped rather than failed.
function Get-RemoteFileLength {
    param ([string]$Url)
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method            = 'HEAD'
        $req.Timeout           = 30000
        $req.AllowAutoRedirect = $true
        $req.UserAgent         = 'RTT-NinjaTransfer'
        try { $req.Proxy = [Net.WebRequest]::GetSystemWebProxy() } catch { }
        $res = $req.GetResponse()
        try { return [long]$res.ContentLength } finally { $res.Close() }
    } catch {
        Write-Log "Could not determine the remote file size (HEAD failed: $($_.Exception.Message)). The size check will be skipped." -Level Warning
        return 0
    }
}

# Validates a downloaded MSI, cheapest check first, each one gating the next.
#
# Why this specific ladder - these were measured against deliberately damaged MSIs:
#   - Magic bytes alone are a FALSE NEGATIVE for every truncation, because the OLE header
#     sits at offset 0 and survives any amount of tail loss. Their real value is as the
#     definitive detector for an HTML block page served with HTTP 200.
#   - WindowsInstaller COM OpenDatabase is ALSO a false negative on a nearly-complete
#     truncation and on in-place corruption, because the MSI tables live at the front of
#     the compound file while the bulk CAB payload is at the end. A file that opens
#     cleanly as a database can still fail during msiexec file extraction, which is the
#     worst outcome: a half-installed agent.
#   - Content-Length agreement is what actually catches the 5.1 truncation bug.
#   - Authenticode is the strongest single check - it covers the whole file, so it detects
#     both truncation and corruption - and it works on per-organization installers because
#     the vendor signs the finished file, something no fixed published hash could do.
#     Verified against the live endpoint: the NinjaOne installer is signed by
#     "CN=NinjaOne LLC, O=NinjaOne LLC, L=Oldsmar, S=Florida, C=US".
#     It is still not made a HARD requirement, for two reasons: the per-organization
#     installer was not available to test (only the generic one), and a revocation-check
#     failure on a restricted or air-gapped network legitimately yields UnknownError on a
#     perfectly good file. So HashMismatch - positive evidence of damage - is fatal, while
#     NotSigned/UnknownError only warn and let the other checks decide.
function Test-InstallerFile {
    param (
        [string]$Path,
        [long]$ExpectedLength = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log 'Validation failed: the file does not exist.' -Level Warning
        return $false
    }

    $len = (Get-Item -LiteralPath $Path).Length

    # A NinjaOne agent MSI is tens of megabytes. Anything under a megabyte is a block
    # page, an error body, or an empty file - never a real installer.
    if ($len -lt 1MB) {
        Write-Log "Validation failed: the file is only $len bytes - too small to be an agent MSI." -Level Warning
        return $false
    }

    if ($ExpectedLength -gt 0 -and $len -ne $ExpectedLength) {
        Write-Log "Validation failed: got $len bytes but the server declared $ExpectedLength. The download was truncated." -Level Warning
        return $false
    }

    # OLE compound-document header: D0 CF 11 E0 A1 B1 1A E1
    # 32 bytes are read rather than 8 because the sector size at offset 30 is needed for
    # the alignment check below.
    $header = New-Object byte[] 32
    $stream = [IO.File]::OpenRead($Path)
    try { $null = $stream.Read($header, 0, 32) } finally { $stream.Dispose() }
    $hex = (($header[0..7]) | ForEach-Object { $_.ToString('X2') }) -join ''

    if ($hex -ne 'D0CF11E0A1B11AE1') {
        Write-Log "Validation failed: this is not an MSI (header bytes: $hex)." -Level Warning
        # Log the start of the file as text. Block pages almost always name the product
        # that blocked them ("Zscaler", "Umbrella", "Access Denied"), which turns an
        # unactionable "install failed" ticket into "allowlist this URL".
        try {
            $peekBytes = [IO.File]::ReadAllBytes($Path)
            $peekLen   = [Math]::Min(512, $peekBytes.Length)
            $peek      = [Text.Encoding]::ASCII.GetString($peekBytes, 0, $peekLen)
            Write-Log "First $peekLen bytes of the response: $peek" -Level Warning
        } catch { }
        return $false
    }

    # Sector-alignment check - the truncation detector that needs no network and no signature.
    #
    # A compound file is built from whole sectors, so its total length is always an exact
    # multiple of the sector size declared at header offset 30 (as a power-of-two shift;
    # 9 = 512-byte sectors, 12 = 4096). A download cut off at an arbitrary byte is almost
    # never sector-aligned, which makes this the check that catches a nearly-complete
    # truncation when the server did not send a Content-Length - the one case where every
    # other check in this ladder returns a false negative. Verified against MSIs truncated
    # to 50%, 95% and 99.9%: all three were misaligned, while the intact file was not.
    #
    # It cannot catch in-place corruption that preserves length (Authenticode does that),
    # and a truncation that lands exactly on a sector boundary would slip through - hence
    # this augments the ladder rather than replacing any part of it.
    try {
        $sectorShift = [BitConverter]::ToUInt16($header, 30)
        if ($sectorShift -ge 7 -and $sectorShift -le 20) {
            $sectorSize = [int][Math]::Pow(2, $sectorShift)
            if (($len % $sectorSize) -ne 0) {
                Write-Log "Validation failed: $len bytes is not a whole number of $sectorSize-byte sectors (remainder $($len % $sectorSize)). The download is truncated." -Level Warning
                return $false
            }
        } else {
            Write-Log "Unexpected compound-file sector shift ($sectorShift); skipping the alignment check." -Level Warning
        }
    } catch {
        Write-Log "The alignment check could not run: $($_.Exception.Message). Continuing." -Level Warning
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            Write-Log "Signature valid. Signer: $($sig.SignerCertificate.Subject)"
            if ($sig.SignerCertificate.Subject -notmatch 'Ninja') {
                Write-Log 'The installer is validly signed but NOT by NinjaOne. Check that the URL points at a NinjaOne installer.' -Level Warning
            }
        } elseif ($sig.Status -eq 'HashMismatch') {
            # Positive evidence that the bytes were altered or truncated.
            Write-Log 'Validation failed: signature hash mismatch - the file is corrupt or incomplete.' -Level Warning
            return $false
        } else {
            Write-Log "Signature not confirmed (status: $($sig.Status)). Continuing on the strength of the size and header checks." -Level Warning
        }
    } catch {
        Write-Log "The signature check could not run: $($_.Exception.Message). Continuing." -Level Warning
    }

    # Final structural check, and a chance to record the product version in the log.
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.OpenDatabase($Path, 0)   # 0 = read-only; never open direct mode
        try {
            $view = $db.OpenView("SELECT Value FROM Property WHERE Property='ProductVersion'")
            # '$null =' is required: this COM call emits a null into the success pipeline,
            # which would otherwise ride along in this function's return value.
            $null = $view.Execute()
            $rec = $view.Fetch()
            if ($rec) { Write-Log "Installer ProductVersion: $($rec.StringData(1))" }
        } catch { }
        $db = $null; $wi = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    } catch {
        Write-Log "Validation failed: not a readable MSI database ($($_.Exception.Message))." -Level Warning
        return $false
    }

    Write-Log "Installer validated: $len bytes." -Level Success
    return $true
}

# --- Individual transports -------------------------------------------------------------
# Each returns $true if it believes it succeeded. None is trusted: the caller
# re-validates the file after every attempt, because several of these can "succeed" while
# leaving a partial or bogus file behind.

# curl.exe: best stall detection (--speed-limit/--speed-time is the only clean way to
# abort a hung transfer) and real resume support. Ships in Windows 10 1803+ and Server
# 2019+, but NOT Server 2016 or older, so it can never be the only path. It uses the
# Schannel backend, so it trusts the Windows certificate store and therefore transparently
# handles a corporate TLS-inspection root - but it ignores the Windows proxy, hence -x.
function Invoke-CurlDownload {
    param ([string]$Url, [string]$Destination)

    $curl = Join-Path (Get-NativeSystem32) 'curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) {
        # Fall back to the redirected path; curl is present under SysWOW64 even though
        # some other tools are not.
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    }
    if (-not (Test-Path -LiteralPath $curl)) {
        Write-Log 'curl.exe is not present on this OS (expected on Server 2016 and older). Skipping.'
        return $false
    }

    $curlArgs = @(
        '--location'                       # follow the app.ninjarmm.com -> resources.ninjarmm.com redirect
        '--fail'
        '--retry', '4'
        '--retry-delay', '3'
        '--connect-timeout', '20'
        '--max-time', '900'
        '--speed-limit', '1024'            # abort if throughput stays under 1 KB/s...
        '--speed-time', '60'               # ...for a full minute, rather than hanging
        '--output', $Destination
        '--silent', '--show-error'
        '--user-agent', 'RTT-NinjaTransfer'
    )

    # --retry-all-errors was added in curl 7.71. Windows 10 1803 shipped 7.55, so this
    # must be probed rather than assumed, or the whole command fails on an older build.
    try {
        $help = & $curl --help all 2>$null
        if ($help -and ($help | Select-String -SimpleMatch '--retry-all-errors' -Quiet)) {
            $curlArgs += '--retry-all-errors'
        }
    } catch { }

    $proxy = Get-SystemProxy
    if ($proxy) {
        Write-Log "Passing the system proxy to curl: $proxy"
        $curlArgs += @('-x', $proxy)
    }

    $curlArgs += $Url

    & $curl @curlArgs 2>&1 | ForEach-Object { if ($_) { Write-Log "curl: $_" } }

    # curl never throws - it signals failure only through its exit code.
    if ($LASTEXITCODE -ne 0) {
        Write-Log "curl.exe exited with code $LASTEXITCODE." -Level Warning
        return $false
    }
    return $true
}

# HttpWebRequest with an explicit stream copy - the approach Chocolatey's Get-WebFile
# uses. It streams straight to disk (no full-response buffering), honours the WinINET
# proxy, exposes both Timeout and ReadWriteTimeout, and lets the Content-Type be inspected
# BEFORE anything is written, so a proxy block page is rejected without touching disk.
function Invoke-WebRequestStreamDownload {
    param ([string]$Url, [string]$Destination)

    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method            = 'GET'
    $req.Timeout           = 60000
    $req.ReadWriteTimeout  = 120000
    $req.AllowAutoRedirect = $true
    $req.UserAgent         = 'RTT-NinjaTransfer'
    try {
        $req.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
    } catch { }
    try { $req.Credentials = [Net.CredentialCache]::DefaultCredentials } catch { }

    $res = $null
    try {
        $res = $req.GetResponse()

        # Reject a text/HTML body before writing. Note the content type is NOT allowlisted:
        # the NinjaOne CDN serves the non-standard 'binary/octet-stream', so allowlisting
        # 'application/octet-stream' would reject the legitimate file.
        $ctype = [string]$res.ContentType
        if ($ctype -match '^(text/|application/(json|xml|xhtml))') {
            Write-Log "The server returned '$ctype' rather than a binary - almost certainly a proxy or filter block page." -Level Warning
            return $false
        }

        $inStream  = $res.GetResponseStream()
        $outStream = [IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 1048576
            while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $read)
            }
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
        return $true
    } catch {
        Write-Log "The stream download failed: $($_.Exception.Message)" -Level Warning
        return $false
    } finally {
        if ($res) { try { $res.Close() } catch { } }
        # Hard teardown so a poisoned connection is not reused from the pool on the next
        # attempt - a subtle detail borrowed from Chocolatey's downloader.
        try { $req.ServicePoint.MaxIdleTime = 0 } catch { }
    }
}

# BITS: the most resilient transport (true resume, checkpointing, survives reboots) and,
# contrary to common folklore, it works fine under SYSTEM - LocalSystem is always
# considered logged on. What actually breaks BITS is a NAMED user who is not interactively
# logged on, impersonation, or the service being disabled by GPO.
#
# The defaults are unusable here and MUST be overridden: -RetryInterval defaults to 600
# seconds and -RetryTimeout to 14 DAYS, so a transient error would park this call for ten
# minutes and look exactly like a hang. A low -RetryTimeout turns that into a fast,
# catchable failure that falls through to the next transport.
function Invoke-BitsDownload {
    param ([string]$Url, [string]$Destination)

    if (-not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        Write-Log 'The BITS module is not available. Skipping.'
        return $false
    }
    $bits = Get-Service BITS -ErrorAction SilentlyContinue
    if (-not $bits) {
        Write-Log 'The BITS service is not present. Skipping.'
        return $false
    }
    if ($bits.Status -ne 'Running') {
        try { Start-Service BITS -ErrorAction Stop; Start-Sleep 2 }
        catch {
            Write-Log 'The BITS service could not be started (it may be disabled by policy). Skipping.' -Level Warning
            return $false
        }
    }

    try {
        Start-BitsTransfer -Source $Url -Destination $Destination `
            -TransferType Download -Priority Foreground `
            -RetryInterval 60 -RetryTimeout 120 -ErrorAction Stop
        return $true
    } catch {
        Write-Log "The BITS transfer failed: $($_.Exception.Message)" -Level Warning
        # A failed synchronous job stays in the queue and must be reaped, or stale jobs leak.
        try {
            Get-BitsTransfer -ErrorAction SilentlyContinue |
                Where-Object { $_.JobState -eq 'Error' } |
                Remove-BitsTransfer -ErrorAction SilentlyContinue
        } catch { }
        return $false
    }
}

# Invoke-WebRequest, last resort. On Windows PowerShell 5.1 this is the weakest option: it
# buffers the whole response in memory, has no resume, its -TimeoutSec bounds only the
# connect/header phase (so a stalled transfer can hang indefinitely), and it carries the
# unfixed silent-truncation bug. -UseBasicParsing is mandatory, not optional: without it
# the response is handed to the Internet Explorer engine, which is absent on Server Core
# and under SYSTEM, producing a "first-launch configuration" error.
function Invoke-IwrDownload {
    param ([string]$Url, [string]$Destination)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        return $true
    } catch {
        Write-Log "Invoke-WebRequest failed: $($_.Exception.Message)" -Level Warning
        return $false
    }
}

# Tries each transport in turn, re-validating the file after every attempt and deleting it
# before falling through. The transports are ordered so their failure modes are
# complementary rather than correlated - each covers a case the others cannot:
#
#   curl.exe           absent on Server 2016 | ignores the Windows proxy | best stall detection
#   HttpWebRequest     works everywhere      | honours the WinINET proxy | inspects headers first
#   BITS               fine under SYSTEM     | needs SetIEProxy         | true resume
#   Invoke-WebRequest  last resort           | silent-truncation bug on 5.1
function Get-InstallerWithFallback {
    param ([string]$Url, [string]$Destination)

    Enable-ModernTls
    $expected = Get-RemoteFileLength -Url $Url
    if ($expected -gt 0) { Write-Log "The server reports an installer size of $expected bytes." }

    $methods = @(
        @{ Name = 'curl.exe';          Action = { Invoke-CurlDownload             -Url $Url -Destination $Destination } }
        @{ Name = 'HttpWebRequest';    Action = { Invoke-WebRequestStreamDownload -Url $Url -Destination $Destination } }
        @{ Name = 'BITS';              Action = { Invoke-BitsDownload             -Url $Url -Destination $Destination } }
        @{ Name = 'Invoke-WebRequest'; Action = { Invoke-IwrDownload              -Url $Url -Destination $Destination } }
    )

    foreach ($m in $methods) {
        Write-Log "Attempting the download via $($m.Name)..."
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }

        $claimed = $false
        try { $claimed = & $m.Action } catch { Write-Log "$($m.Name) threw: $($_.Exception.Message)" -Level Warning }

        if ($claimed) {
            if (Test-InstallerFile -Path $Destination -ExpectedLength $expected) {
                Write-Log "The download succeeded via $($m.Name)." -Level Success
                # Clear Mark-of-the-Web; under some SRP/AppLocker/attachment-manager
                # policies the Internet-zone tag alone can block execution.
                try { Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue } catch { }
                return $true
            }
            Write-Log "$($m.Name) reported success but the file failed validation. Trying the next method." -Level Warning
        }
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
    return $false
}

# ==============================================================================
# AGENT DISCOVERY
# ==============================================================================

# Finds NinjaOne uninstall entries across BOTH registry views explicitly.
#
# This replaces a hardcoded WOW6432Node path, which had two problems. First, a 32-bit
# PowerShell host cannot see the native 64-bit registry view through the PS provider at
# all, so a natively-registered agent was invisible. Second, the 32-bit OS branch omitted
# the trailing '\*', so Get-ItemProperty read the parent key's own values and could never
# match a child entry - it found nothing, every time.
#
# Matching is also broadened from an exact 'NinjaRMMAgent' DisplayName to any Ninja-named
# entry with an msiexec uninstall string, so a differently-named agent still matches.
function Get-NinjaUninstallEntries {
    $found = @()
    $views = if ([Environment]::Is64BitOperatingSystem) { @('Registry64', 'Registry32') } else { @('Registry32') }

    foreach ($viewName in $views) {
        try {
            $view = [Microsoft.Win32.RegistryView]::$viewName
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            try {
                $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if (-not $uninstall) { continue }
                try {
                    foreach ($name in $uninstall.GetSubKeyNames()) {
                        $sub = $uninstall.OpenSubKey($name)
                        if (-not $sub) { continue }
                        try {
                            $displayName  = [string]$sub.GetValue('DisplayName')
                            $uninstallStr = [string]$sub.GetValue('UninstallString')
                            if ($displayName -match 'Ninja' -and $uninstallStr -match 'msiexec') {
                                # Distinguish the agent itself from other Ninja-branded
                                # products. Matching every 'Ninja' entry is too blunt: a
                                # real machine can also carry e.g. "NinjaRMM Desktop
                                # Companion x64" in the NATIVE view, which is a separate
                                # product with its own code. Only agent entries are
                                # uninstalled; the rest are reported for review.
                                $isAgent = $displayName -match $AgentNamePattern
                                # Extract the product GUID by regex. The previous approach
                                # split the string on the character 'X', which is
                                # case-sensitive and silently produced $null for a
                                # lowercase '/x{GUID}' - skipping the MSI uninstall while
                                # still running the destructive cleanup.
                                $guid = [regex]::Match($uninstallStr,
                                    '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}').Value
                                $found += [PSCustomObject]@{
                                    View            = $viewName
                                    DisplayName     = $displayName
                                    DisplayVersion  = [string]$sub.GetValue('DisplayVersion')
                                    UninstallString = $uninstallStr
                                    ProductCode     = $guid
                                    IsAgent         = $isAgent
                                }
                            }
                        } finally { $sub.Close() }
                    }
                } finally { $uninstall.Close() }
            } finally { $base.Close() }
        } catch {
            Write-Log "Could not read the $viewName registry view: $($_.Exception.Message)" -Level Warning
        }
    }
    return $found
}

# Resolves the agent's install directory from the registry, falling back to the service
# binary path when the registry value is missing or stale after a partial uninstall.
function Get-NinjaInstallLocation {
    foreach ($viewName in @('Registry32', 'Registry64')) {
        try {
            $view = [Microsoft.Win32.RegistryView]::$viewName
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            try {
                foreach ($path in @('SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent',
                                    'SOFTWARE\NinjaRMM LLC\NinjaRMMAgent')) {
                    $key = $base.OpenSubKey($path)
                    if (-not $key) { continue }
                    try {
                        $loc = [string]$key.GetValue('Location')
                        # The Location value can use forward slashes.
                        if ($loc) { $loc = $loc.Replace('/', '\') }
                        if ($loc -and (Test-Path -LiteralPath (Join-Path $loc 'NinjaRMMAgent.exe'))) { return $loc }
                    } finally { $key.Close() }
                }
            } finally { $base.Close() }
        } catch { }
    }

    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='NinjaRMMAgent'" -ErrorAction SilentlyContinue
        if ($svc -and $svc.PathName) { return (Split-Path $svc.PathName.Trim('"')) }
    } catch { }

    return $null
}

# Reports Windows Installer product keys that have no ProductName.
#
# A valid product key always has one. Keys missing it can indicate a corrupt or partial
# Ninja install, and per NinjaOne's removal guide this is the one documented cause of a
# subsequent agent install refusing to proceed. They are only ever REPORTED, never deleted:
# other products can legitimately share this shape and damaging them would be worse than a
# failed transfer. The excluded GUID is a known Windows common component that has no
# ProductName by design.
#
# This runs during the SURVEY, before anything is modified. NinjaOne's own script performs
# the same check but prints it as its very last action - which is the least likely line to
# ever be reached, because tearing down the agent can kill the script's own process tree
# partway through. Running it up front means the warning is in the log even if this run is
# terminated at the uninstall. The result is the same either way: every key this deletes
# later has a ProductName by definition, so removal cannot change the orphan set.
function Write-OrphanedInstallerKeyReport {
    try {
        $orphans = New-Object System.Collections.ArrayList
        Get-ChildItem 'HKLM:\Software\Classes\Installer\Products' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -match '99E80CA9B0328e74791254777B1F42AE') { return }
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $props -or $null -eq $props.ProductName) { [void]$orphans.Add($_.PSChildName) }
        }
        if ($orphans.Count -gt 0) {
            Write-Log 'Some installer registry keys have no ProductName - possibly a corrupt Ninja install entry.' -Level Warning
            Write-Log 'If the new agent fails to install, back up and then review these keys:' -Level Warning
            $orphans | ForEach-Object { Write-Log "  $_" -Level Warning }
        }
    } catch {
        Write-Log "The orphaned key check failed (non-fatal): $($_.Exception.Message)" -Level Warning
    }
}

# ==============================================================================
# REMOVAL HELPERS
# ==============================================================================

# Runs the NinjaRMM MSI uninstaller silently, following NinjaOne's documented method for
# handling Uninstall Prevention (ref: NinjaOne Removal Guide).
#
# NinjaOne's documented steps when Uninstall Prevention is active:
#   1. Ensure the NinjaRMMAgent service is running.
#   2. Run: NinjaRMMAgent.exe -disableUninstallPrevention
#   3. Run: uninstall.exe --mode unattended
#
# Step 3 is done via msiexec /x rather than uninstall.exe directly: the NinjaOne MSI is
# wrapped by EXEMSI, and WRAPPED_ARGUMENTS passes "--mode unattended" through the wrapper
# to the inner uninstaller - functionally equivalent.
#
# Calling -disableUninstallPrevention is safe whether or not prevention is actually
# enabled; it is a no-op if it was never activated. Its state cannot be inspected from
# outside the agent and there is no documented failure code, so it is best-effort by
# necessity - which is exactly why the file/service/registry cleanup still runs afterwards.
# Prevention is an account-global setting that pushes down to agents, so the uninstall
# runs immediately after disabling rather than minutes later.
function Uninstall-NinjaMSI {
    param (
        [string]$ProductCode,
        [string]$InstallLocation
    )

    $svc = Get-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Log 'Starting the NinjaRMMAgent service so uninstall prevention can be lifted...'
        Start-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
        Start-Sleep 5
    }

    if ($InstallLocation) {
        $agentExe = Join-Path $InstallLocation 'NinjaRMMAgent.exe'
        if (Test-Path -LiteralPath $agentExe) {
            Write-Log 'Disabling uninstall prevention...'
            Start-Process $agentExe -ArgumentList '-disableUninstallPrevention', 'NOUI' -ErrorAction SilentlyContinue
            Start-Sleep 10
        } else {
            Write-Log "NinjaRMMAgent.exe was not found at $InstallLocation - skipping the uninstall-prevention step." -Level Warning
        }
    } else {
        Write-Log 'The install location is unknown - skipping the uninstall-prevention step.' -Level Warning
    }

    $msiLog = Join-Path $StateDir 'msi-uninstall.log'
    $msiArgs = @(
        "/x$ProductCode"
        '/quiet'
        '/norestart'
        '/L*V'
        "`"$msiLog`""
        'WRAPPED_ARGUMENTS="--mode unattended"'
    )
    Write-Log "Running: msiexec.exe /x$ProductCode (log: $msiLog)"
    $proc = Start-Process 'msiexec.exe' -ArgumentList $msiArgs -Wait -NoNewWindow -PassThru
    Write-Log "msiexec exited with code $($proc.ExitCode)."
    # 0 = success, 1605 = not installed (already gone), 3010 = success, reboot required.
    if ($proc.ExitCode -notin @(0, 1605, 3010)) {
        Write-Log "Unexpected msiexec exit code $($proc.ExitCode) - continuing with manual cleanup." -Level Warning
    }
    # Let background agent processes terminate before file and registry cleanup.
    Start-Sleep 30
}

# Removes Ninja Remote (ncstreamer) registry entries from one user profile hive.
# Ninja Remote writes autostart entries to the user's Run key and stores settings under
# "NinjaRMM LLC". This must be cleaned from every user profile - both currently loaded
# hives and profiles that are not logged in. The caller loads/unloads unmounted hives.
function Remove-NRRegistryItems {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SID
    )
    $runKey = "Registry::HKEY_USERS\$SID\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $njKey  = "Registry::HKEY_USERS\$SID\Software\NinjaRMM LLC"

    if (Test-Path $runKey) {
        $values = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
        if ($values) {
            $values.PSObject.Properties |
                Where-Object { $_.Name -match 'NinjaRMM|NinjaOne' } |
                ForEach-Object {
                    Write-Log "Removing Run entry: $($_.Name)"
                    Remove-ItemProperty -Path $runKey -Name $_.Name -Force -ErrorAction SilentlyContinue
                }
        }
    }
    if (Test-Path $njKey) {
        Write-Log "Removing: $njKey"
        Remove-Item $njKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Removes the Ninja Remote virtual display driver.
#
# Two portability problems are handled here. pnputil.exe does not exist under SysWOW64,
# so a 32-bit host must reach it through Sysnative or driver cleanup silently no-ops. And
# the output is LOCALIZED - field labels like "Published Name" are translated on
# non-English Windows - so blocks are matched on the .inf filename and the published name
# is taken as the FIRST field of the matching block, whose position is language
# independent. Splitting on ':' with a limit of 2 also keeps values that contain a colon
# (paths, dates, versions) intact, and each match is deleted individually rather than
# passing an array to pnputil.
function Remove-NRDisplayDriver {
    $pnputil = Join-Path (Get-NativeSystem32) 'pnputil.exe'
    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Log 'pnputil.exe was not found - skipping display driver removal.' -Level Warning
        return
    }

    $output = & $pnputil /enum-drivers 2>&1
    if (-not $output) { return }

    $blocks = @(); $current = @()
    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count) { $blocks += , $current; $current = @() }
        } else {
            $current += $line
        }
    }
    if ($current.Count) { $blocks += , $current }

    foreach ($block in $blocks) {
        if (($block -join "`n") -notmatch 'nrvirtualdisplay\.inf') { continue }
        $firstField = $block | Where-Object { $_ -match ':' } | Select-Object -First 1
        if (-not $firstField) { continue }
        $published = ($firstField -split ':', 2)[1].Trim()
        if (-not $published) { continue }
        Write-Log "Removing the Ninja Remote display driver: $published"
        & $pnputil /delete-driver $published /force 2>&1 | ForEach-Object { if ($_) { Write-Log "pnputil: $_" } }
    }
}

# ==============================================================================
# INSTALL TASK
# ==============================================================================

# The install helper that the Scheduled Task runs. Written to disk rather than passed as
# an -EncodedCommand so it is inspectable on a failed machine and not subject to
# command-line length limits.
$InstallHelperScript = @'
param (
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [Parameter(Mandatory = $true)][string]$StateDir,
    [int]$MaxRemovalWaitMinutes = 30,
    [string]$TaskName = 'NinjaRMM-NewAgentInstall'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$log             = Join-Path $StateDir 'install.log'
$removalDoneFlag = Join-Path $StateDir 'removal.done'
$installDoneFlag = Join-Path $StateDir 'install.done'

# Write-Host rather than Write-Output, for the same reason as the parent script: keeping
# log lines out of the success pipeline so they can never contaminate a function's
# return value.
function Write-InstallLog {
    param ([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

# Detects whether the AGENT is still installed. Deliberately scoped to the agent rather
# than to anything named 'Ninja': a machine can carry other Ninja-branded products (e.g.
# "NinjaRMM Desktop Companion x64") that this transfer leaves in place by design. Matching
# those would make this function report the agent as still present forever, which would
# block the early-exit below and fire a spurious "still present" warning on every run.
function Test-NinjaInstalled {
    if (Get-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue) { return $true }
    $agentPattern = '^NinjaRMMAgent$|NinjaOne\s*Agent|^NinjaRMM\s*Agent$'
    $views = if ([Environment]::Is64BitOperatingSystem) { @('Registry64', 'Registry32') } else { @('Registry32') }
    foreach ($viewName in $views) {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::$viewName)
            $un = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($un) {
                foreach ($n in $un.GetSubKeyNames()) {
                    $s = $un.OpenSubKey($n)
                    if ($s) {
                        $dn = [string]$s.GetValue('DisplayName')
                        $s.Close()
                        if ($dn -match $agentPattern) { $un.Close(); $base.Close(); return $true }
                    }
                }
                $un.Close()
            }
            $base.Close()
        } catch { }
    }
    return $false
}

function Complete-Task {
    param ([string]$Reason)
    Write-InstallLog $Reason
    New-Item -ItemType File -Path $installDoneFlag -Force | Out-Null
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-InstallLog "Scheduled task '$TaskName' unregistered."
    } catch {
        Write-InstallLog "Could not unregister the task: $($_.Exception.Message)"
    }
}

Write-InstallLog '--- Install task fired ---'

if (Test-Path -LiteralPath $installDoneFlag) {
    Complete-Task 'The install already completed on an earlier run. Nothing to do.'
    exit 0
}

# Wait for the removal phase to finish before installing. This is what makes the fixed
# delay non-load-bearing: rather than assuming removal fits in a set number of minutes,
# the task waits for an explicit signal. Without this the task could fire mid-cleanup, and
# the name-based cleanup would then delete the BRAND-NEW agent's service, files and
# registry keys - the removal has no way to tell the two instances apart.
#
# The wait also ends early once the incumbent agent has actually gone, which covers the
# case where the parent script was killed by the agent teardown before it could write the
# signal. If neither condition is met, the install proceeds anyway on timeout: a machine
# with a possibly-imperfect agent is far better than a machine with none.
$deadline = (Get-Date).AddMinutes($MaxRemovalWaitMinutes)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $removalDoneFlag) {
        Write-InstallLog 'Removal signalled complete.'
        break
    }
    if (-not (Test-NinjaInstalled)) {
        Write-InstallLog 'The incumbent agent is gone with no completion signal - the removal script was probably terminated. Proceeding.'
        break
    }
    Start-Sleep -Seconds 15
}

if (-not (Test-Path -LiteralPath $removalDoneFlag) -and (Test-NinjaInstalled)) {
    Write-InstallLog "WARNING: waited $MaxRemovalWaitMinutes minute(s) and a Ninja agent is still present. Installing anyway; if this fails, the incumbent agent was not fully removed."
}

# AV and endpoint protection can quarantine or delete a downloaded installer AFTER the
# download reported success, so the file is re-checked immediately before it is used.
if (-not (Test-Path -LiteralPath $MsiPath)) {
    Write-InstallLog "ERROR: the installer is missing from $MsiPath (deleted or quarantined?). Cannot install."
    exit 1
}
$msiLen = (Get-Item -LiteralPath $MsiPath).Length
if ($msiLen -lt 1MB) {
    Write-InstallLog "ERROR: the installer at $MsiPath is only $msiLen bytes. Refusing to run it."
    exit 1
}

$msiexecLog = Join-Path $StateDir 'msi-install.log'
Write-InstallLog "Installing the agent from $MsiPath ($msiLen bytes)..."
$proc = Start-Process 'msiexec.exe' `
    -ArgumentList @('/i', "`"$MsiPath`"", '/quiet', '/norestart', '/L*V', "`"$msiexecLog`"") `
    -Wait -NoNewWindow -PassThru
Write-InstallLog "msiexec exited with code $($proc.ExitCode)."

# Verify the agent is actually present rather than trusting the exit code. This is the
# check that turns a silent failure into a visible one.
$verifyDeadline = (Get-Date).AddMinutes(5)
$installed = $false
while ((Get-Date) -lt $verifyDeadline) {
    $svc = Get-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Running') { try { Start-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue } catch { } }
        $installed = $true
        break
    }
    Start-Sleep -Seconds 10
}

if ($installed) {
    $svc = Get-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
    Complete-Task "SUCCESS: the NinjaRMMAgent service is present (status: $($svc.Status)). The device should check in shortly."
    Remove-Item -LiteralPath $MsiPath -Force -ErrorAction SilentlyContinue
    exit 0
}

# Leave the task registered so its repetition trigger retries. Exiting non-zero also
# surfaces the failure in the task's Last Run Result.
Write-InstallLog "FAILURE: the NinjaRMMAgent service did not appear after the install (msiexec exit $($proc.ExitCode)). See $msiexecLog. The task will retry."
exit 1
'@

# Registers the one-time-plus-retry Scheduled Task that installs the new agent as SYSTEM.
#
# The task is the sole install path: it runs outside this script's process tree, so it
# survives the MSI uninstaller terminating this process. NinjaOne's scripting engine runs
# inside the Ninja process tree, and the entire tree is torn down when the agent is
# removed. The MSI is already on disk before this is called, so the task needs no network.
#
# The settings and triggers here are load-bearing, and each is a fix for a way the
# previous version silently failed to install:
#   -AllowStartIfOnBatteries / -DontStopIfGoingOnBatteries
#       The scheduled-task defaults are DisallowStartIfOnBatteries = True and
#       StopIfGoingOnBatteries = True. Without these two overrides the task simply never
#       runs on a laptop that is not plugged in - which alone accounts for a transfer that
#       works on desktops and "randomly" fails on laptops.
#   -StartWhenAvailable
#       Defaults to False, meaning a trigger missed because the machine was off, asleep or
#       rebooting at the appointed minute is skipped permanently rather than run late.
#   AtStartup trigger
#       Covers a reboot during removal (the MSI uninstall can request one).
#   Repetition on the Once trigger
#       Retries on a schedule, so a transient failure self-heals instead of leaving the
#       machine with no agent. The helper unregisters the task once it verifies success,
#       so the repetition costs nothing on a healthy machine.
function Register-InstallTask {
    param (
        [string]$MsiPath,
        [string]$StateDir,
        [string]$HelperPath,
        [int]$DelayMinutes,
        [int]$MaxRemovalWaitMinutes,
        [int]$RetryWindowHours
    )

    Set-Content -LiteralPath $HelperPath -Value $InstallHelperScript -Encoding UTF8 -Force

    $arguments = '-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden ' +
                 "-File `"$HelperPath`" -MsiPath `"$MsiPath`" -StateDir `"$StateDir`" " +
                 "-MaxRemovalWaitMinutes $MaxRemovalWaitMinutes -TaskName `"$TaskName`""

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    $triggers = @()
    $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($DelayMinutes) `
        -RepetitionInterval (New-TimeSpan -Minutes 15) `
        -RepetitionDuration (New-TimeSpan -Hours $RetryWindowHours)
    try {
        $triggers += New-ScheduledTaskTrigger -AtStartup
    } catch {
        Write-Log 'Could not add a startup trigger; the timed trigger alone will be used.' -Level Warning
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null

    Write-Log ("Install task registered. First attempt at approximately {0}, then retrying every 15 minutes for up to {1} hour(s) until the agent is verified." -f `
        (Get-Date).AddMinutes($DelayMinutes).ToString('HH:mm:ss'), $RetryWindowHours) -Level Success
    Write-Log "To cancel: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
}

# ==============================================================================
# MAIN
# ==============================================================================

Write-Log "=== Reinstall NinjaRMM Agent v$ScriptVersion ==="

# --- Resolve the installer URL ---
if ($env:installerUrl) { $InstallerURL = $env:installerUrl }
if (-not $InstallerURL -and $NewMSPInstallerURL) { $InstallerURL = $NewMSPInstallerURL }

if (-not $InstallerURL) {
    Write-Log 'No installer URL provided. Set $NewMSPInstallerURL in the script, pass -InstallerURL, or configure the "installerUrl" Ninja script variable.' -Level Error
    exit 1
}
if ($InstallerURL -notmatch '^https://') {
    Write-Log "The installer URL must be HTTPS. Got: $InstallerURL" -Level Error
    exit 1
}

# --- Preflight ---
# Reported up front because these are the variables that determine which of the known
# failure modes apply, and this log is what gets read when a machine goes quiet.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Log "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Log "OS         : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
Write-Log "Process    : $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }) on $(if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }) Windows"
Write-Log "Identity   : $([Security.Principal.WindowsIdentity]::GetCurrent().Name) (elevated: $isAdmin)"
Write-Log "State dir  : $StateDir"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Log "PowerShell $($PSVersionTable.PSVersion) is not supported - this script needs 3.0 or later for the ScheduledTasks cmdlets." -Level Error
    exit 1
}
if (-not $isAdmin) {
    Write-Log 'This script must run elevated (as SYSTEM or an administrator).' -Level Error
    exit 1
}
if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    Write-Log 'The ScheduledTasks module is unavailable, so the install could not be made to survive the agent removal. Refusing to proceed - removing the agent now would leave this device unmanaged.' -Level Error
    exit 1
}

try {
    # --- Survey the incumbent agent ---
    # Note there can legitimately be MORE THAN ONE agent uninstall entry, each with its
    # own product code (observed on a real machine: two NinjaRMMAgent registrations).
    # Every one of them must be uninstalled - leaving a stray MSI product record behind is
    # the one documented cause of a subsequent agent install refusing to proceed.
    $allNinja        = @(Get-NinjaUninstallEntries)
    $entries         = @($allNinja | Where-Object { $_.IsAgent })
    $otherProducts   = @($allNinja | Where-Object { -not $_.IsAgent })
    $installLocation = Get-NinjaInstallLocation

    if ($entries.Count -eq 0) {
        Write-Log 'No NinjaOne agent was found in the registry. Treating this as a clean install.' -Level Warning
    } else {
        foreach ($e in $entries) {
            $pc = if ($e.ProductCode) { $e.ProductCode } else { '<could not parse>' }
            Write-Log "Found agent: '$($e.DisplayName)' $($e.DisplayVersion) [$($e.View)] ProductCode=$pc"
        }
        if ($entries.Count -gt 1) {
            Write-Log "$($entries.Count) agent registrations are present; all of them will be uninstalled."
        }
    }

    # Other Ninja-branded products are reported but deliberately left alone: they have
    # their own product codes, do not block an agent install, and blindly removing
    # anything matching 'Ninja' on an unfamiliar fleet risks collateral damage.
    foreach ($o in $otherProducts) {
        Write-Log "Other Ninja product found (NOT removed - review if the install fails): '$($o.DisplayName)' $($o.DisplayVersion) [$($o.View)]" -Level Warning
    }

    Write-Log "Install location: $(if ($installLocation) { $installLocation } else { '<not found>' })"

    Write-OrphanedInstallerKeyReport

    # --- Download and validate BEFORE touching anything ---
    # If the URL is unreachable, expired, or intercepted, the run aborts here with the
    # machine completely untouched. An expired installer URL returns a small HTML error
    # body that "downloads" successfully, which is exactly how a device ends up with no
    # agent at all - hence the validation ladder in Test-InstallerFile.
    Write-Log "Downloading the new agent installer from: $InstallerURL"
    if (-not (Get-InstallerWithFallback -Url $InstallerURL -Destination $MsiPath)) {
        Write-Log 'Every download method failed or produced an invalid installer. No changes have been made to this machine.' -Level Error
        exit 1
    }

    if ($DryRun) {
        Write-Log 'DryRun specified: the installer is valid and the machine has been surveyed. Nothing was removed or installed.' -Level Success
        Write-Log "The validated installer has been left at: $MsiPath"
        exit 0
    }

    # --- Register the install task before touching the agent ---
    Remove-Item -LiteralPath $RemovalDoneFlag -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallDoneFlag -Force -ErrorAction SilentlyContinue
    Register-InstallTask -MsiPath $MsiPath -StateDir $StateDir -HelperPath $HelperPs1 `
        -DelayMinutes $InstallDelayMinutes -MaxRemovalWaitMinutes $MaxRemovalWaitMinutes `
        -RetryWindowHours $RetryWindowHours

    # From here on the machine is being modified, and a partial cleanup is preferable to an
    # early abort, so errors become non-fatal. Note the consequence: try/catch no longer
    # traps non-terminating errors, so anything that must be caught below uses an explicit
    # -ErrorAction Stop.
    $ErrorActionPreference = 'Continue'

    Write-Log '--- Beginning NinjaRMM agent removal ---'

    # --- Run the MSI uninstaller ---
    if ($entries.Count -eq 0) {
        Write-Log 'There is no uninstall entry to run. Proceeding straight to cleanup.' -Level Warning
    } else {
        foreach ($e in $entries) {
            if (-not $e.ProductCode) {
                Write-Log "Could not parse a product code from '$($e.UninstallString)' - skipping the MSI uninstall for this entry." -Level Warning
                continue
            }
            Uninstall-NinjaMSI -ProductCode $e.ProductCode -InstallLocation $installLocation
        }
    }

    # --- Stop processes and services ---
    # Done AFTER the MSI uninstall: the agent has a patcher/watchdog
    # (NinjaRMMAgentPatcher) that can resurrect components if they are killed too early.
    $ninjaProcesses = @('NinjaRMMAgent', 'NinjaRMMAgentPatcher', 'njbar', 'NinjaRMMProxyProcess64', 'ncstreamer')
    foreach ($p in $ninjaProcesses) {
        Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # sc.exe DELETE rather than Remove-Service, which is PowerShell 6+ only.
    # 'lockhart' is the Ninja Backup service and is only present on some installations.
    $ninjaServices = @('NinjaRMMAgent', 'nmsmanager', 'lockhart', 'ncstreamer')
    foreach ($s in $ninjaServices) {
        if (Get-Service $s -ErrorAction SilentlyContinue) {
            Write-Log "Deleting service: $s"
            & sc.exe DELETE $s | Out-Null
            Start-Sleep 2
            if (Get-Service $s -ErrorAction SilentlyContinue) {
                Write-Log "Service '$s' is still present after the delete (a reboot may be required)." -Level Warning
            }
        }
    }

    # --- Remove directories ---
    # $env:ProgramData\NinjaRMMAgent holds tenant policy and config; leaving it risks the
    # new agent picking up stale settings, so NinjaOne's guide treats it as mandatory.
    $dirsToRemove = @(
        $installLocation
        (Join-Path $env:ProgramData 'NinjaRMMAgent')
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\NJCliPSh')
        (Join-Path $env:ProgramFiles 'NinjaRemote')
    ) | Where-Object { $_ }

    foreach ($dir in $dirsToRemove) {
        if (Test-Path -LiteralPath $dir) {
            Write-Log "Removing directory: $dir"
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dir) { Write-Log "Failed to remove: $dir" -Level Warning }
        }
    }

    # NinjaOne's guide warns there may be MULTIPLE install folders under Program Files (x86)
    # - one per org/site/version - and that all of them must go. The install location from
    # the registry names only one, so siblings are swept here too.
    #
    # Folders are identified by CONTAINING NinjaRMMAgent.exe rather than by having 'Ninja'
    # in the name. That matters in both directions: the agent installs to a path built from
    # the org and site names, which need not contain "Ninja" at all, while a Ninja-named
    # folder can belong to a different product (an observed machine had a 'NinjaDesktop'
    # folder holding the Desktop Companion and no agent binary - deleting it would have
    # stranded a product this script deliberately leaves installed).
    # Wildcard expansion at fixed depths rather than -Recurse: the agent lives at
    # <org>\<site>\<version>\NinjaRMMAgent.exe at worst, and recursing every folder in
    # Program Files (Office, Visual Studio, ...) would cost minutes at exactly the point
    # where the machine is between agents. Note -Path, not -LiteralPath, so the wildcards
    # are expanded by the provider.
    $agentDirsToRemove = New-Object System.Collections.ArrayList
    foreach ($pfRoot in @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $pfRoot)) { continue }
        foreach ($depth in @('*', '*\*', '*\*\*')) {
            Get-Item -Path (Join-Path $pfRoot "$depth\NinjaRMMAgent.exe") -ErrorAction SilentlyContinue |
                ForEach-Object {
                    # Walk back up to the folder directly beneath Program Files: the whole
                    # org tree goes, per NinjaOne's "remove all of them" instruction.
                    $top = $_.Directory
                    while ($top.Parent -and $top.Parent.FullName -ne $pfRoot.TrimEnd('\')) { $top = $top.Parent }
                    [void]$agentDirsToRemove.Add($top.FullName)
                }
        }
    }
    foreach ($dir in ($agentDirsToRemove | Select-Object -Unique)) {
        if ($installLocation -and $dir -eq $installLocation.TrimEnd('\')) { continue }  # already handled above
        Write-Log "Removing additional agent directory: $dir"
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Remove registry entries ---
    # Ninja leaves traces across several locations. All matching keys are collected first,
    # then deleted in one pass.
    #   Uninstall           - Add/Remove Programs entries
    #   MSI Wrapper         - EXEMSI wrapper entries created when the MSI was installed
    #   Products (S-1-5-18) - Windows Installer product records under the SYSTEM SID
    #   HKCR Installer      - Windows Installer product cache, keyed by packed GUID
    #
    # These are all scoped to the AGENT ($AgentNamePattern), not to everything matching
    # 'Ninja'. Deleting another Ninja product's Windows Installer records while leaving the
    # product installed would strand it - unable to be serviced or uninstalled - so a
    # non-agent product is reported during the survey instead and left entirely alone.
    Write-Log 'Removing registry entries...'
    $regKeysToRemove = New-Object System.Collections.ArrayList

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        # The trailing '\*' is essential: without it Get-ItemProperty returns the parent
        # key's own values and never matches a child entry.
        Get-ItemProperty "$root\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $AgentNamePattern } |
            ForEach-Object { [void]$regKeysToRemove.Add($_.PSPath) }
    }

    # The EXEMSI wrapper key is named after the agent package, so it is matched on the
    # agent pattern rather than a bare 'Ninja'.
    foreach ($wrapper in @(
        'HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed'
        'HKLM:\SOFTWARE\EXEMSI.COM\MSI Wrapper\Installed')) {
        Get-ChildItem $wrapper -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match $AgentNamePattern } |
            ForEach-Object { [void]$regKeysToRemove.Add($_.PSPath) }
    }

    $productsRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    Get-ChildItem $productsRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty (Join-Path $_.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
        if ($props -and $props.DisplayName -match $AgentNamePattern) { [void]$regKeysToRemove.Add($_.PSPath) }
    }

    Get-ChildItem 'Registry::HKEY_CLASSES_ROOT\Installer\Products' -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props -and $props.ProductName -match $AgentNamePattern) { [void]$regKeysToRemove.Add($_.PSPath) }
    }

    foreach ($njKey in @(
        'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC'
        'HKLM:\SOFTWARE\NinjaRMM LLC')) {
        if (Test-Path $njKey) { [void]$regKeysToRemove.Add($njKey) }
    }

    foreach ($key in ($regKeysToRemove | Select-Object -Unique)) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        Write-Log "Removing: $key"
        Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $key) { Write-Log "Failed to remove registry key: $key" -Level Warning }
    }

    # --- Remove Ninja Remote ---
    Write-Log '--- Removing Ninja Remote ---'
    Remove-NRDisplayDriver

    # S-1-5-18 is the SYSTEM SID; Ninja Remote can leave a key there as well as per-user.
    $systemNRKey = 'Registry::HKEY_USERS\S-1-5-18\Software\NinjaRMM LLC'
    if (Test-Path $systemNRKey) { Remove-Item $systemNRKey -Recurse -Force -ErrorAction SilentlyContinue }

    # Enumerate real user profiles, excluding the built-in service accounts (S-1-5-18/19/20).
    # BOTH SID families are matched deliberately:
    #   S-1-5-21-*  local accounts and on-premises AD accounts (incl. hybrid-joined devices)
    #   S-1-12-1-*  Microsoft Entra ID accounts on an Entra-joined (cloud-only) device
    # NinjaOne's own removal script matches only S-1-5-21-*, so on a cloud-only fleet it
    # sweeps ZERO real user profiles and leaves every user's Ninja Remote autostart entry
    # and settings key behind.
    # Loaded hives are already in HKU; profiles that are not logged in need NTUSER.DAT mounted.
    $profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -like 'S-1-5-21-*' -or $_.SID -like 'S-1-12-1-*' })
    Write-Log "$($profiles.Count) user profile(s) to clean."

    foreach ($userProfile in ($profiles | Where-Object { $_.Loaded })) {
        Write-Log "Cleaning Ninja Remote registry items for: $($userProfile.LocalPath)"
        Remove-NRRegistryItems -SID $userProfile.SID
    }

    foreach ($userProfile in ($profiles | Where-Object { -not $_.Loaded })) {
        $hive = Join-Path $userProfile.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        Write-Log "Loading the hive for: $($userProfile.LocalPath)"
        & reg.exe LOAD "HKU\$($userProfile.SID)" $hive 2>&1 | Out-Null
        Remove-NRRegistryItems -SID $userProfile.SID
        # PowerShell can hold registry handles that block REG UNLOAD until the managed
        # objects referencing the hive are released, so collection is forced first.
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe UNLOAD "HKU\$($userProfile.SID)" 2>&1 | Out-Null
    }

    $nrPrinter = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'NinjaRemote' }
    if ($nrPrinter) {
        Write-Log 'Removing the Ninja Remote printer...'
        Remove-Printer -InputObject $nrPrinter -ErrorAction SilentlyContinue
    }

    $nrSpool = Join-Path $env:SystemDrive 'Users\Public\Documents\NrSpool'
    if (Test-Path -LiteralPath $nrSpool) {
        Write-Log 'Removing the Ninja Remote print spool...'
        Remove-Item -LiteralPath $nrSpool -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Signal completion so the install task can proceed immediately ---
    Write-Log 'Removal complete. Signalling the install task.' -Level Success
    New-Item -ItemType File -Path $RemovalDoneFlag -Force | Out-Null

    # Nudge the task rather than waiting for its trigger, so a successful removal installs
    # in seconds instead of minutes. Harmless if it fails - the trigger still fires.
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Log 'Install task started.'
    } catch {
        Write-Log "Could not start the install task early; it will fire on its own trigger. ($($_.Exception.Message))" -Level Warning
    }

    Write-Log "Done. Track progress in $StateDir\install.log, and watch the new NinjaOne device timeline for the check-in." -Level Success
    exit 0
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level Error
    Write-Log "At: $($_.InvocationInfo.PositionMessage)" -Level Error
    # The install task, if it was registered, is left in place deliberately - it is what
    # recovers this machine. Do not clean it up on the way out.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Log "The install task '$TaskName' is still registered and will attempt the install." -Level Warning
    } else {
        Write-Log 'No install task is registered. This device may be left without an agent - investigate immediately.' -Level Error
    }
    exit 1
}
