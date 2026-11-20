#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stops Microsoft Edge Copilot from reading page content from the browser.

.DESCRIPTION
    Sets the machine-wide Microsoft Edge policies that block Copilot in the Edge
    side pane from accessing page content (and, per Microsoft, browsing history and
    video transcripts) when a user is signed in to Edge with a work or school
    (Entra ID) account. Use it when a customer is concerned about Copilot reading
    information from their other open tabs.

    Two policies are written under HKLM:\SOFTWARE\Policies\Microsoft\Edge, both
    REG_DWORD, both set to 0 (Disabled):

      EdgeEntraCopilotPageContext   Copilot with enterprise data protection, which
                                    includes Microsoft 365 Copilot Chat. Edge 130+.
      CopilotPageContext            Copilot without enterprise data protection for
                                    Entra profiles. Edge 124+. Microsoft documents
                                    this as a separate control, so both are set.

    Microsoft documents that disabling either policy also disables
    M365LinksAutoOpenCopilotEnabled. The policies are per-profile, mandatory and
    refresh dynamically, so Edge picks them up without a restart (check
    edge://policy and use Reload policies if needed).

    Limits to know about:
      - Neither policy applies to personal Microsoft account (MSA) profiles.
      - This does not hide Copilot or the sidebar. Copilot can still be opened,
        it just cannot read the page. To remove the icon or sidebar, use
        Microsoft365CopilotChatIconEnabled or HubsSidebarEnabled instead.
      - The obsolete CopilotCDPPageContext policy (removed after Edge 132) is not
        written.
      - Microsoft's documentation does not say whether Edge "Copilot Mode"
        features are governed by these policies. Confirm behavior on a test
        device if that matters to the customer.

    The script is idempotent: values already set are left alone, and each value is
    read back after writing to confirm it took effect.

.PARAMETER Revert
    Deletes both policy values so Edge returns to its default (Copilot may read
    page content outside the EU; users can change it in Edge settings).
    Env: REVERT (true/1).

.NOTES
    Designed for NinjaOne RMM deployment at SYSTEM level. Also runs directly with
    Administrator rights. Compatible with Windows PowerShell 5.1 and PowerShell 7.

    Environment Variables (NinjaOne / RMM):
      REVERT - (optional) true/1, see -Revert.

    Exit codes: 0 = policies are in the requested state, 1 = a value could not be
    written or did not read back correctly.

    Sources (Microsoft Learn, Edge policy reference):
      https://learn.microsoft.com/deployedge/microsoft-edge-browser-policies/edgeentracopilotpagecontext
      https://learn.microsoft.com/deployedge/microsoft-edge-browser-policies/copilotpagecontext

.EXAMPLE
    .\Disable Edge Copilot Page Context.ps1

.EXAMPLE
    .\Disable Edge Copilot Page Context.ps1 -Revert
#>

param(
    [switch]$Revert
)

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# Configuration (NinjaOne environment variables override parameters)
# ------------------------------------------------------------------------------
if ($env:REVERT -match '^(true|1|yes)$') { $Revert = $true }

$PolicyPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$PolicyNames = @('EdgeEntraCopilotPageContext', 'CopilotPageContext')

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

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
function Get-PolicyValue {
    param([string]$Name)
    $item = Get-ItemProperty -Path $PolicyPath -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}

function Set-PolicyDisabled {
    param([string]$Name)
    if ((Get-PolicyValue $Name) -eq 0) {
        Write-Log "$Name is already 0 (Disabled)."
        return
    }
    New-ItemProperty -Path $PolicyPath -Name $Name -Value 0 -PropertyType DWord -Force | Out-Null
    $actual = Get-PolicyValue $Name
    if ($actual -ne 0) { throw "$Name reads back as '$actual' after being set to 0." }
    Write-Log "$Name set to 0 (Disabled)." 'Success'
}

function Remove-Policy {
    param([string]$Name)
    if ($null -eq (Get-PolicyValue $Name)) {
        Write-Log "$Name is not set."
        return
    }
    Remove-ItemProperty -Path $PolicyPath -Name $Name -Force
    if ($null -ne (Get-PolicyValue $Name)) { throw "$Name is still present after removal." }
    Write-Log "$Name removed." 'Success'
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
try {
    if ($Revert) {
        Write-Log 'Reverting: removing Edge Copilot page context policies.'
        if (Test-Path $PolicyPath) {
            foreach ($name in $PolicyNames) { Remove-Policy $name }
        } else {
            Write-Log 'Edge policy key does not exist, nothing to remove.'
        }
    } else {
        Write-Log 'Disabling Edge Copilot access to page content.'
        if (-not (Test-Path $PolicyPath)) {
            New-Item -Path $PolicyPath -Force | Out-Null
        }
        foreach ($name in $PolicyNames) { Set-PolicyDisabled $name }
        Write-Log 'Applies to Entra ID profiles only; personal Microsoft account profiles are not covered by these policies.' 'Warn'
    }
    exit 0
}
catch {
    Write-Log "Failed: $($_.Exception.Message)" 'Error'
    exit 1
}
