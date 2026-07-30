#Requires -Version 7
<#
.SYNOPSIS
    Creates an Exchange Online transport rule to quarantine inbound mail not from AppRiver.

.DESCRIPTION
    Connects to Exchange Online and creates a transport rule that quarantines
    incoming external email unless it was delivered by AppRiver ETP (Email
    Threat Protection). Optionally includes additional IP addresses such as
    copier scan-to-email WAN IPs.

.NOTES
    Name:    Configure AppRiver Inbound Limit
    Author:  RTT Support
    Context: Technician workstation (interactive)
    Ref:     https://support.zixcorp.com/app/answers/detail/a_id/2933/kw/inbound%20route%20limit
#>

param()

# Ensure PowerShellGet is current enough to reliably install modules on older systems
try {
    $psGet = Get-Module -ListAvailable -Name PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if ($psGet.Version -lt [Version]'2.0') {
        Write-Host "Updating PowerShellGet before installing dependencies..."
        Install-Module -Name PowerShellGet -Scope CurrentUser -Force -AllowClobber
        throw "PowerShellGet updated. Please restart PowerShell and re-run this script."
    }
} catch {
    Write-Warning "Could not check/update PowerShellGet: $($_.Exception.Message)"
}

# Install Exchange Online module if not already installed
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "Installing ExchangeOnlineManagement module..."
    try {
        Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        throw "Failed to install ExchangeOnlineManagement: $($_.Exception.Message)"
    }
}

# Import the module
try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
} catch {
    throw "Failed to import ExchangeOnlineManagement: $($_.Exception.Message)"
}

# Connect to Exchange Online
# -Device uses device code flow (browser-based), which avoids the WAM window handle
# error that occurs when running from an elevated or non-standard terminal context.
Connect-ExchangeOnline -DisableWAM

# AppRiver IP ranges as an array for readability
$appRiverIPs = @(
    '5.152.184.128/25',
    '5.152.185.128/26',
    '8.19.118.0/24',
    '8.31.233.0/24',
    '69.20.58.224/28',
    '5.152.188.0/24',
    '199.187.164.0/24',
    '199.187.165.0/24',
    '199.187.166.0/24',
    '199.187.167.0/24',
    '69.25.26.128/26',
    '204.232.250.0/24',
    '74.203.184.184/32',
    '74.203.184.185/32',
    '199.30.235.11/32',
    '74.203.185.12/32'
)

# Prompt for additional IP addresses
Write-Output "You can enter additional IP addresses or subnets to include in the transport rule."
Write-Output "It may be helpful to include a client's static WAN IP address in case they have a copier with scan to email."
$additionalIPsInput = Read-Host "Enter any additional IP addresses or subnets (comma-delimited), or press Enter to skip:"

# Append additional IPs to the array if provided
if ($additionalIPsInput.Trim()) {
    $additionalIPs = $additionalIPsInput -split ',' | ForEach-Object { $_.Trim() }
    $appRiverIPs += $additionalIPs
}

# Convert individual IPs (without CIDR notation) to /32 subnets
$appRiverIPs = $appRiverIPs | ForEach-Object {
    if ($_ -match '^\d+\.\d+\.\d+\.\d+$') {
        # IP without CIDR notation - convert to /32
        "$_/32"
    } else {
        # Already has CIDR notation - keep as is
        $_
    }
}

# Splat parameters for New-TransportRule to keep the command multi-line and readable
$params = @{
    Name                                  = 'Limit Inbound Mail to AppRiver (Quarantine direct send)'
    Comments                              = 'This rule will quarantine incoming external email if the message was not delivered by ETP. This rule should only be active for ETP customers and it must be disabled if ETP service is cancelled.'
    SenderAddressLocation                 = 'Header'
    FromScope                             = 'NotInOrganization'
    Quarantine                            = $true
    SetSCL                                = 6
    ExceptIfSenderIpRanges                = $appRiverIPs
    Enabled                               = $true
    Priority                              = 0
    ExceptIfHeaderContainsMessageHeader   = 'x-ms-exchange-meetingforward-message'
    ExceptIfHeaderContainsWords           = 'Forward'
    ExceptIfHeaderMatchesMessageHeader    = 'X-MS-Exchange-CrossTenant-AuthAs'
    ExceptIfHeaderMatchesPatterns         = 'Internal'
    ExceptIfMessageTypeMatches            = 'Voicemail'
}

New-TransportRule @params

# Reference: https://support.zixcorp.com/app/answers/detail/a_id/2933/kw/inbound%20route%20limit
