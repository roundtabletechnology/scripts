#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detects competing RMM agents and remote access tools on Windows.

.DESCRIPTION
    NinjaOne agents cannot be installed by more than one MSP on the same device,
    and other MSPs' agents (ConnectWise Automate, Datto RMM, Kaseya, N-able, Atera,
    Syncro, ...) and remote access tools (ScreenConnect, AnyDesk, TeamViewer, ...)
    are a sign the device is still managed by someone else. This script finds them.

    Each product in the catalog is classified as:

      RMM            A management agent from another MSP / RMM vendor. Treat as a
                     conflict to resolve before or during onboarding.
      Remote access  A remote support or remote control tool. Often legitimate
                     (a client's own TeamViewer), but worth reviewing.

    Evidence is gathered from five places, then matched against the catalog:

      1. Installed programs   Uninstall registry keys (64-bit, 32-bit, and every
                              loaded user hive).
      2. Services             Name or display name.
      3. Running processes    Process name.
      4. File paths           Program Files, ProgramData, Windows, and per-user
                              locations under every profile (catches portable and
                              per-user installs such as AnyDesk or RustDesk).
      5. Catalog              Each product is "Active" when a service or process is
                              running and "Installed" when only files, an uninstall
                              entry, or a stopped service remain.

    The NinjaOne agent itself is reported as informational and is never counted as
    a conflict, since this script normally runs from it. Use -PreOnboarding when
    scanning a device that is NOT yet under your NinjaOne instance (run from a
    different tool): any NinjaOne agent found is then another MSP's.

    The result is written to a NinjaOne custom device field and printed to stdout.

.PARAMETER PreOnboarding
    Treat a NinjaOne agent as a competing RMM. Env: PRE_ONBOARDING (true/1).

.PARAMETER Ignore
    Product names to leave out, for tools your own company uses (for example
    'ScreenConnect','Splashtop'). Matched case-insensitively against the catalog
    names printed in the output. Env: IGNORE_PRODUCTS (comma separated).

.PARAMETER FailOnDetect
    Exit 2 when a competing RMM (not just a remote access tool) is found, so the
    run can be used as a NinjaOne condition. Env: FAIL_ON_DETECT (true/1).

.NOTES
    Designed for NinjaOne RMM deployment at SYSTEM level. Also runs directly with
    Administrator rights. Compatible with Windows PowerShell 5.1 and PowerShell 7.

    Environment Variables (NinjaOne / RMM):
      NINJA_FIELD_NAME - (optional) Custom field to write the result into.
                         Defaults to "competingRmm". Set to empty to skip.
      PRE_ONBOARDING   - (optional) true/1, see -PreOnboarding.
      IGNORE_PRODUCTS  - (optional) comma separated, see -Ignore.
      FAIL_ON_DETECT   - (optional) true/1, see -FailOnDetect.

    Exit codes: 0 = scan completed (whether or not anything was found),
                1 = the scan failed, 2 = -FailOnDetect and a competing RMM found.

    Per-user detection covers hives that are loaded plus well-known per-user
    folders under every profile. A per-user install by a user who has never
    signed in on this boot and leaves no matching folder can be missed.

    Not covered on purpose: overlay networks / tunnels (Tailscale, ZeroTier,
    ngrok), built-in tools (Quick Assist, Remote Desktop), and MDM platforms
    (see Mac/Security/Detect MDM Enrollment.sh for Macs).

.EXAMPLE
    .\Detect Competing RMM.ps1

.EXAMPLE
    .\Detect Competing RMM.ps1 -PreOnboarding -Ignore 'ScreenConnect','Splashtop'
#>

param(
    [switch]$PreOnboarding,
    [string[]]$Ignore,
    [switch]$FailOnDetect
)

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# Configuration (NinjaOne environment variables override parameters)
# ------------------------------------------------------------------------------
function Test-Truthy {
    param([string]$Value)
    return ($Value -match '^(true|1|yes)$')
}

$NinjaFieldName = if ($null -ne $env:NINJA_FIELD_NAME) { $env:NINJA_FIELD_NAME } else { 'competingRmm' }
if (Test-Truthy $env:PRE_ONBOARDING) { $PreOnboarding = $true }
if (Test-Truthy $env:FAIL_ON_DETECT) { $FailOnDetect = $true }
if ($env:IGNORE_PRODUCTS) {
    $Ignore = @($Ignore) + @($env:IGNORE_PRODUCTS -split ',')
}
$Ignore = @($Ignore | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )
    $prefix = switch ($Level) {
        'Info'    { '[INFO]   ' }
        'Success' { '[SUCCESS]' }
        'Warn'    { '[WARN]   ' }
        'Error'   { '[ERROR]  ' }
    }
    if ($Level -eq 'Error') {
        [Console]::Error.WriteLine("$prefix $Message")
    } else {
        Write-Host "$prefix $Message"
    }
}

# ==============================================================================
# Product catalog
#
#   Name   Friendly name (also what -Ignore matches).
#   Type   'RMM', 'Remote' (remote access), or 'Own' (NinjaOne, see below).
#   Match  Regex tested against installed-program names, service names, service
#          display names and process names. Keep it specific: it is the main
#          cause of false positives.
#   Paths  Wildcard paths (Test-Path -Path, so * works) checked as-is.
#   User   Paths relative to each user profile folder.
#
# Sources: vendor documentation, the LOLRMM catalog (lolrmm.io), and agent
# footprints observed on managed devices. Add new products at the bottom of
# the matching section.
# ==============================================================================
function New-Product {
    param([string]$Name, [string]$Type, [string]$Match, [string[]]$Paths = @(), [string[]]$User = @())
    [PSCustomObject]@{ Name = $Name; Type = $Type; Match = $Match; Paths = $Paths; User = $User }
}

$catalog = @(
    # ---- Own RMM ----------------------------------------------------------------
    New-Product 'NinjaOne' 'Own' '^(NinjaRMMAgent|NinjaOne|NinjaRMM|ncstreamer|NinjaRemote)' `
        @('C:\Program Files*\NinjaRemote', 'C:\ProgramData\NinjaRMMAgent', 'C:\Program Files*\NinjaRMMAgent')

    # ---- Competing RMM platforms ------------------------------------------------
    New-Product 'ConnectWise Automate (LabTech)' 'RMM' '^(LTService|LTSvcMon|LTSVC|LabTech|ConnectWise Automate)' `
        @('C:\Windows\LTSvc')
    New-Product 'ConnectWise RMM (Continuum)' 'RMM' '^(ITSPlatform|SAAZ|Continuum|ConnectWise RMM)' `
        @('C:\Program Files*\ITSPlatform', 'C:\Program Files*\SAAZOD')
    New-Product 'Datto RMM (CentraStage)' 'RMM' '^(CagService|AEMAgent|Datto RMM|CentraStage|Autotask Endpoint Management)' `
        @('C:\Program Files*\CentraStage', 'C:\ProgramData\CentraStage')
    New-Product 'Kaseya VSA' 'RMM' '^(Kaseya Agent|KaseyaAgent|AgentMon|Kaseya Live Connect)' `
        @('C:\Program Files*\Kaseya', 'C:\ProgramData\Kaseya')
    New-Product 'N-able N-central' 'RMM' '^(Windows Agent Service|Windows Agent Maintenance Service|N-able Technologies|N-central|Windows Agent$)' `
        @('C:\Program Files*\N-able Technologies', 'C:\Program Files*\Msp Agent')
    New-Product 'N-able RMM (SolarWinds MSP)' 'RMM' '^(Advanced Monitoring Agent|SolarWinds MSP|N-able RMM|winagent)' `
        @('C:\Program Files*\Advanced Monitoring Agent*', 'C:\Program Files*\SolarWinds MSP')
    New-Product 'Atera' 'RMM' '^(AteraAgent|Atera Agent|ATERA Networks)' `
        @('C:\Program Files*\ATERA Networks')
    New-Product 'Syncro (Kabuto)' 'RMM' '^(Syncro|Kabuto|RepairTech)' `
        @('C:\ProgramData\Syncro', 'C:\Program Files*\RepairTech', 'C:\Program Files*\Syncro', 'C:\Program Files*\Kabuto*')
    New-Product 'SuperOps' 'RMM' '^(SuperOps|superopsticket)' `
        @('C:\Program Files*\SuperOps', 'C:\ProgramData\SuperOps')
    New-Product 'Pulseway' 'RMM' '^(Pulseway|PC Monitor|pcmonitorsrv|PCMonitorManager)' `
        @('C:\Program Files*\Pulseway', 'C:\Program Files*\PC Monitor')
    New-Product 'Level' 'RMM' '^Level($|[ _-]?(agent|remote))' `
        @('C:\Program Files\Level')
    New-Product 'Action1' 'RMM' '^(A1Agent|Action1)' `
        @('C:\Windows\Action1', 'C:\Program Files*\Action1')
    New-Product 'ManageEngine Endpoint Central / RMM Central' 'RMM' '^(ManageEngine.*(Agent|Endpoint|UEMS)|DesktopCentral|dcagentservice|UEMS)' `
        @('C:\Program Files*\DesktopCentral_Agent', 'C:\Program Files*\ManageEngine\UEMS_Agent')
    New-Product 'Tactical RMM' 'RMM' '^(tacticalrmm|tacticalagent|Tactical RMM)' `
        @('C:\Program Files\TacticalAgent', 'C:\ProgramData\TacticalRMM')
    New-Product 'ImmyBot' 'RMM' '^ImmyBot' `
        @('C:\Program Files*\ImmyBot*')
    New-Product 'Itarian / Comodo One' 'RMM' '^(ITarian|Itarian|Comodo (ITSM|One|Endpoint Manager)|COMODO ITSM|ITSMService)' `
        @('C:\Program Files*\COMODO\Comodo ITSM', 'C:\Program Files*\ITarian')
    New-Product 'Quest KACE' 'RMM' '^((Quest|Dell) KACE|KACE |KAgent|AMPAgent)' `
        @('C:\Program Files*\Quest\KACE', 'C:\Program Files*\Dell\KACE')
    New-Product 'PDQ Connect' 'RMM' '^PDQ ?Connect' `
        @()
    New-Product 'Naverisk' 'RMM' '^Naverisk' `
        @('C:\Program Files*\Naverisk')
    New-Product 'Domotz' 'RMM' '^Domotz' `
        @('C:\Program Files*\Domotz')
    New-Product 'GoTo Resolve (GoToAssist Corporate)' 'RMM' '^(GoTo Resolve|GoToResolve|GoToAssist|GoToOpener|g2ax)' `
        @('C:\Program Files*\GoTo Resolve*', 'C:\Program Files*\GoToAssist*', 'C:\Program Files*\Citrix\GoToAssist*')
    New-Product 'Faronics Deploy / Core' 'RMM' '^(Faronics|FaronicsCore|DFServ)' `
        @('C:\Program Files*\Faronics')
    New-Product 'Absolute (Computrace)' 'RMM' '^(Absolute|rpcnet|Computrace)' `
        @('C:\Program Files*\Absolute Software', 'C:\Windows\System32\rpcnetp.exe')
    New-Product 'Ivanti / LANDesk' 'RMM' '^(Ivanti Endpoint|LANDesk|LDMS|Ivanti Agent|issuser|Ivanti Security Controls)' `
        @('C:\Program Files*\LANDesk', 'C:\Program Files*\Ivanti\Ivanti Agent')
    New-Product 'Tanium' 'RMM' '^(Tanium|TaniumClient)' `
        @('C:\Program Files*\Tanium')
    New-Product 'Zabbix Agent' 'RMM' '^Zabbix Agent' `
        @('C:\Program Files*\Zabbix Agent*')
    New-Product 'Site24x7 / Network Monitoring Agent' 'RMM' '^(Site24x7|Zoho Monitoring)' `
        @('C:\Program Files*\Site24x7')
    New-Product 'Senso.cloud' 'RMM' '^Senso([ .]?cloud| Agent)' `
        @('C:\Program Files*\Senso*')
    New-Product 'Remotely (open source)' 'RMM' '^Remotely' `
        @('C:\Program Files*\Remotely')
    New-Product 'GLPI / OCS Inventory Agent' 'RMM' '^(GLPI-Agent|GLPI Agent|OCS Inventory)' `
        @('C:\Program Files*\GLPI-Agent', 'C:\Program Files*\OCS Inventory Agent')

    # ---- Remote access / support tools -----------------------------------------
    New-Product 'ScreenConnect (ConnectWise Control)' 'Remote' '^(ScreenConnect|ConnectWise Control)' `
        @('C:\Program Files*\ScreenConnect Client*')
    New-Product 'AnyDesk' 'Remote' '^AnyDesk' `
        @('C:\Program Files*\AnyDesk*', 'C:\ProgramData\AnyDesk') `
        @('AppData\Roaming\AnyDesk')
    New-Product 'TeamViewer' 'Remote' '^TeamViewer' `
        @('C:\Program Files*\TeamViewer') `
        @('AppData\Roaming\TeamViewer')
    New-Product 'Splashtop' 'Remote' '^(Splashtop|SplashtopRemoteService|SRServer|SRManager|SRService|SRAgent)' `
        @('C:\Program Files*\Splashtop')
    New-Product 'LogMeIn / GoTo' 'Remote' '^(LogMeIn|LMIGuardian|GoToMyPC|GoTo Opener|GoTo Connect)' `
        @('C:\Program Files*\LogMeIn*', 'C:\Program Files*\Citrix\GoToMyPC*')
    New-Product 'RustDesk' 'Remote' '^RustDesk' `
        @('C:\Program Files*\RustDesk') `
        @('AppData\Roaming\RustDesk', 'AppData\Local\rustdesk')
    New-Product 'Zoho Assist' 'Remote' '^(Zoho Assist|ZohoMeeting|ZohoURS|ZAService)' `
        @('C:\Program Files*\ZohoMeeting', 'C:\ProgramData\ZohoMeeting')
    New-Product 'BeyondTrust (Bomgar)' 'Remote' '^(BeyondTrust|Bomgar|bomgar-scc|Remote Support Jump Client)' `
        @('C:\ProgramData\Bomgar*', 'C:\ProgramData\BeyondTrust*', 'C:\Program Files*\Bomgar*', 'C:\Program Files*\BeyondTrust*')
    New-Product 'N-able Take Control (BeAnywhere)' 'Remote' '^(BASupSrvc|BASupApp|BASupportExpress|Take Control|BeAnywhere|MSP Anywhere)' `
        @('C:\Program Files*\BeAnywhere*', 'C:\Program Files*\Take Control*', 'C:\Program Files*\SolarWinds MSP\Take Control*')
    New-Product 'MeshCentral (Mesh Agent)' 'Remote' '^(Mesh Agent|MeshAgent|MeshCentral)' `
        @('C:\Program Files*\Mesh Agent')
    New-Product 'SimpleHelp' 'Remote' '^(SimpleHelp|SimpleService|SimpleGatewayService)' `
        @('C:\Program Files*\SimpleHelp', 'C:\ProgramData\JWrapper*')
    New-Product 'NetSupport Manager' 'Remote' '^(NetSupport|client32|NetSupportManager)' `
        @('C:\Program Files*\NetSupport*')
    New-Product 'DWService (DWAgent)' 'Remote' '^(DWAgent|DWService)' `
        @('C:\Program Files*\DWAgent')
    New-Product 'Chrome Remote Desktop' 'Remote' '^(Chrome Remote Desktop|chromoting|remoting_host)' `
        @('C:\Program Files*\Google\Chrome Remote Desktop')
    New-Product 'RemotePC' 'Remote' '^(RemotePC|RPCService|RemotePCDesktop)' `
        @('C:\Program Files*\RemotePC*')
    New-Product 'Remote Utilities' 'Remote' '^(Remote Utilities|RemoteUtilities|rutserv|rfusclient)' `
        @('C:\Program Files*\Remote Utilities*')
    New-Product 'Radmin' 'Remote' '^(Radmin|RServer3|r_server)' `
        @('C:\Program Files*\Radmin*', 'C:\Windows\SysWOW64\rserver30')
    New-Product 'VNC (RealVNC / UltraVNC / TightVNC)' 'Remote' '^(VNC Server|VNC Connect|RealVNC|uvnc|UltraVNC|winvnc|TightVNC|tvnserver)' `
        @('C:\Program Files*\RealVNC', 'C:\Program Files*\uvnc*', 'C:\Program Files*\UltraVNC', 'C:\Program Files*\TightVNC')
    New-Product 'NoMachine' 'Remote' '^(NoMachine|nxservice)' `
        @('C:\Program Files*\NoMachine')
    New-Product 'Supremo' 'Remote' '^Supremo' `
        @('C:\Program Files*\Supremo*', 'C:\ProgramData\SupremoRemoteDesktop')
    New-Product 'HopToDesk' 'Remote' '^HopToDesk' `
        @('C:\Program Files*\HopToDesk')
    New-Product 'Iperius Remote' 'Remote' '^Iperius ?Remote' `
        @('C:\Program Files*\Iperius*')
    New-Product 'ISL Online / ISL Light' 'Remote' '^(ISL Light|ISL Online|ISLLight|ISLAlwaysOn)' `
        @('C:\Program Files*\ISL Online')
    New-Product 'DameWare' 'Remote' '^(DameWare|dwrcs|DWRCS)' `
        @('C:\Program Files*\DameWare*', 'C:\Windows\dwrcs')
    New-Product 'AweSun / SunLogin / ToDesk' 'Remote' '^(AweSun|SunloginClient|Sunlogin|ToDesk)' `
        @('C:\Program Files*\Oray\SunLogin*', 'C:\Program Files*\ToDesk') `
        @('AppData\Roaming\ToDesk')
    New-Product 'AeroAdmin / Ammyy Admin' 'Remote' '^(AeroAdmin|Ammyy)' `
        @() `
        @('AppData\Roaming\AMMYY')
    New-Product 'GetScreen / UltraViewer / Getscreen.me' 'Remote' '^(Getscreen|UltraViewer)' `
        @('C:\Program Files*\Getscreen*', 'C:\Program Files*\UltraViewer')
    New-Product 'Parsec' 'Remote' '^Parsec$|^Parsec ' `
        @('C:\Program Files*\Parsec')
    New-Product 'FleetDeck / Rport / ScreenMeet' 'Remote' '^(FleetDeck|rport|ScreenMeet)' `
        @('C:\Program Files*\FleetDeck*', 'C:\Program Files*\rport*', 'C:\Program Files*\ScreenMeet*')
)

# ==============================================================================
# Evidence collection
# ==============================================================================
function Get-ProgramNames {
    # Display names from the machine-wide uninstall keys (both views) and every
    # loaded user hive. SYSTEM only sees loaded hives, which is why per-user
    # folder checks exist as well.
    $roots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $userHives = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' })
    foreach ($h in $userHives) {
        $roots += "Registry::HKEY_USERS\$($h.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    }

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayName) {
                [PSCustomObject]@{ Name = [string]$props.DisplayName; Version = [string]$props.DisplayVersion }
            }
        }
    }
}

function Get-ProfilePaths {
    $profilesRoot = Join-Path $env:SystemDrive 'Users'
    @(Get-ChildItem $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
        ForEach-Object { $_.FullName })
}

# ==============================================================================
# Main
# ==============================================================================
try {
    Write-Log 'Scanning for competing RMM agents and remote access tools...'

    $programs  = @(Get-ProgramNames)
    $services  = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    $profiles  = @(Get-ProfilePaths)

    $findings = New-Object 'System.Collections.Generic.List[object]'

    foreach ($product in $catalog) {
        if ($Ignore | Where-Object { $product.Name -like "*$_*" }) { continue }

        $evidence = New-Object 'System.Collections.Generic.List[string]'
        $active = $false

        foreach ($p in ($programs | Where-Object { $_.Name -match $product.Match })) {
            $ver = if ($p.Version) { " $($p.Version)" } else { '' }
            $evidence.Add("installed program '$($p.Name)$ver'")
        }
        foreach ($s in ($services | Where-Object { $_.Name -match $product.Match -or $_.DisplayName -match $product.Match })) {
            $evidence.Add("service '$($s.Name)' ($($s.State))")
            if ($s.State -eq 'Running') { $active = $true }
        }
        foreach ($proc in ($processes | Where-Object { $_.ProcessName -match $product.Match } | Select-Object -ExpandProperty ProcessName -Unique)) {
            $evidence.Add("process '$proc'")
            $active = $true
        }
        foreach ($path in $product.Paths) {
            foreach ($hit in @(Resolve-Path -Path $path -ErrorAction SilentlyContinue)) { $evidence.Add("path '$($hit.ProviderPath)'") }
        }
        foreach ($rel in $product.User) {
            foreach ($prof in $profiles) {
                $full = Join-Path $prof $rel
                if (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue) { $evidence.Add("path '$full'") }
            }
        }

        if ($evidence.Count -eq 0) { continue }

        $type = $product.Type
        if ($type -eq 'Own' -and $PreOnboarding) { $type = 'RMM' }

        $findings.Add([PSCustomObject]@{
            Name     = $product.Name
            Type     = $type
            State    = if ($active) { 'Active' } else { 'Installed' }
            Evidence = @($evidence | Select-Object -Unique)
        })
    }

    $rmm    = @($findings | Where-Object { $_.Type -eq 'RMM' })
    $remote = @($findings | Where-Object { $_.Type -eq 'Remote' })
    $own    = @($findings | Where-Object { $_.Type -eq 'Own' })

    # --------------------------------------------------------------------------
    # Output summary
    # --------------------------------------------------------------------------
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'Competing RMM / Remote Access Detection'
    if ($PreOnboarding) { Write-Host '(pre-onboarding mode: NinjaOne agents count as competing)' }
    if ($Ignore.Count -gt 0) { Write-Host "(ignored: $($Ignore -join ', '))" }
    Write-Host '============================================================'

    foreach ($group in @(
            @{ Title = 'Competing RMM agents';   Items = $rmm },
            @{ Title = 'Remote access tools';    Items = $remote },
            @{ Title = 'Own agent (informational)'; Items = $own })) {
        if ($group.Items.Count -eq 0) { continue }
        Write-Host "$($group.Title):"
        foreach ($f in $group.Items) {
            Write-Host "  - $($f.Name) [$($f.State)]"
            foreach ($e in $f.Evidence) { Write-Host "      $e" }
        }
    }
    if ($rmm.Count -eq 0 -and $remote.Count -eq 0) {
        Write-Host 'No competing RMM agents or remote access tools detected.'
    }

    $parts = @()
    if ($rmm.Count -gt 0)    { $parts += 'RMM: ' + (($rmm | ForEach-Object { if ($_.State -eq 'Installed') { "$($_.Name) (inactive)" } else { $_.Name } }) -join ', ') }
    if ($remote.Count -gt 0) { $parts += 'Remote access: ' + (($remote | ForEach-Object { if ($_.State -eq 'Installed') { "$($_.Name) (inactive)" } else { $_.Name } }) -join ', ') }
    $result = if ($parts.Count -gt 0) { $parts -join ' | ' } else { 'None detected' }

    Write-Host '------------------------------------------------------------'
    Write-Host "Reported value: $result"
    Write-Host '============================================================'

    # --------------------------------------------------------------------------
    # Write to NinjaOne custom field
    # --------------------------------------------------------------------------
    if ($NinjaFieldName) {
        try {
            if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
                Ninja-Property-Set $NinjaFieldName $result
                Write-Log "Wrote '$result' to Ninja field '$NinjaFieldName'." 'Success'
            } else {
                Write-Log "Ninja-Property-Set not available (not running under NinjaOne) - skipping field write." 'Warn'
            }
        } catch {
            Write-Log "Could not write to Ninja field '$NinjaFieldName': $($_.Exception.Message)" 'Warn'
        }
    }

    if ($FailOnDetect -and $rmm.Count -gt 0) { exit 2 }

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'Error'
    if ($NinjaFieldName) {
        try { if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) { Ninja-Property-Set $NinjaFieldName 'Failed audit' } } catch {}
    }
    exit 1
}

exit 0
