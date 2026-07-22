#Requires -Version 5.1

<#
.SYNOPSIS
    Audits Windows Server Update Services (WSUS) settings, removes them, and repairs the Windows Update Agent. Determines if WSUS settings are configured in the registry and identifies if they are managed via Group Policy (GPO). You can also write the results to a text custom field, optionally remove the WSUS settings from the registry, reset the Windows Update cache, and test connectivity to Microsoft's Windows Update endpoints.
.DESCRIPTION
    Audits Windows Server Update Services (WSUS) settings, removes them, and repairs the Windows Update Agent. Determines if WSUS settings are configured in the registry and identifies if they are managed via Group Policy (GPO). You can also write the results to a text custom field, optionally remove the WSUS settings from the registry, reset the Windows Update cache, and test connectivity to Microsoft's Windows Update endpoints.

    This script exists to clean up after decommissioned/stale WSUS servers. Clearing the registry settings alone is often not enough - the Windows Update Agent, BITS, and Group Policy can all keep referencing (or silently re-tattoo) the old server, which shows up as scan failures such as "There is no route or network connectivity to the endpoint" (0x80240438). The -ResetWindowsUpdateCache and -TestWindowsUpdateConnectivity switches address the two most common causes of that symptom once the registry is confirmed clean: a stale local Windows Update cache, and outbound firewall/proxy rules that only ever allowed traffic to the internal WSUS server.

.PARAMETER CustomFieldName
    The name of the custom field to set with WSUS settings information.

.PARAMETER RemoveWSUSSettings
    If specified, removes the WSUS policy registry key (the same key GPOs write WSUS settings to) after it has been detected and reported on. If no WSUS registry settings are found, no action is taken and this is reported.

.PARAMETER ResetWindowsUpdateCache
    If specified, stops the BITS, Windows Update, Cryptographic Services, and Update Orchestrator services, renames the SoftwareDistribution and catroot2 cache folders (Microsoft's documented Windows Update component reset), and restarts those services. This forces the Windows Update Agent to rebuild its cache and drop any stale/cached reference to a decommissioned WSUS server instead of continuing to use it until the next reboot. The next patch scan afterward will take longer than usual while the cache rebuilds.

.PARAMETER TestWindowsUpdateConnectivity
    If specified, tests DNS resolution and TCP connectivity to a representative set of Microsoft's published Windows Update, Delivery Optimization, and Automatic Root Certificate Update endpoints. Useful when an environment previously relied on WSUS exclusively and outbound firewall/proxy rules were never opened for direct internet access to Microsoft's update servers.

.PARAMETER UnregisterStaleUpdateServices
    If specified, unregisters any stale WSUS/third-party update service that is still bound to the Windows Update Agent (as surfaced by the service-binding inspection) via the Microsoft.Update.ServiceManager COM API. This is the fix for a WSUS service that remains the DefaultAUService even after every WSUS registry value and GPO has been removed - a state that -ResetWindowsUpdateCache does NOT clear, because the service registration lives outside the SoftwareDistribution cache folder. Removing it makes the agent fall back to the built-in Windows Update / Microsoft Update service so scans stop failing 0x80240438 against a server that no longer exists.

.EXAMPLE
    (No Parameters)

    [Info] Script Version: 1.12
    [Info] Updating group policies...
    [Info] Group policy update completed successfully.

    [Info] Checking the registry for WSUS settings...
    [Info] WSUS Update Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562
    [Info] WSUS Statistics Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562

    [Info] Checking for GPOs that configure WSUS settings...
    [Info] Found GPOs that affect WSUS settings.

    ### Active WSUS settings: ###

    WSUS Settings Source : GPO
    WSUS Status          : Enabled
    GPO Display Name     : A_WSUS_Settings
    Update Server        : https://test.local.another.sub.domain/test/testagain:8562
    Statistics Server    : https://test.local.another.sub.domain/test/testagain:8562

.EXAMPLE
    -CustomFieldName "WSUSSettings"

    [Info] Script Version: 1.12
    [Info] Updating group policies...
    [Info] Group policy update completed successfully.

    [Info] Checking the registry for WSUS settings...
    [Info] WSUS Update Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562
    [Info] WSUS Statistics Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562

    [Info] Checking for GPOs that configure WSUS settings...
    [Info] Found GPOs that affect WSUS settings.

    ### Active WSUS settings: ###

    WSUS Settings Source : GPO
    WSUS Status          : Enabled
    GPO Display Name     : A_WSUS_Settings
    Update Server        : https://test.local.another.sub.domain/test/testagain:8562
    Statistics Server    : https://test.local.another.sub.domain/test/testagain:8562

    [Info] Currently applied Group Policy Objects: Default Domain Policy, A_WSUS_Settings, Local Group Policy
    [Info] Of those, the following appear related to WSUS/Windows Update by name: A_WSUS_Settings

    [Info] Setting the custom field 'WSUSSettings' with the value:
    WSUS Status: Enabled | Update and Statistics Server: https://test.local.another.sub.domain/test/testagain:8562 | GPO Name: A_WSUS_Settings | Applied GPOs: A_WSUS_Settings
    [Info] Successfully set the custom field 'WSUSSettings'.

.EXAMPLE
    -RemoveWSUSSettings -CustomFieldName "WSUSSettings"

    [Info] Script Version: 1.12
    [Info] Checking the registry for WSUS settings...
    [Info] WSUS Update Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562
    [Info] WSUS Statistics Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562

    ### Active WSUS settings: ###

    WSUS Settings Source : Registry
    WSUS Status          : Enabled
    Update Server        : https://test.local.another.sub.domain/test/testagain:8562
    Statistics Server    : https://test.local.another.sub.domain/test/testagain:8562

    [Info] Removing WSUS settings from the registry...
    [Info] Removing WSUS registry settings at 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'...
    [Info] Successfully removed WSUS registry settings at 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'.
    [Info] Restarting the 'wuauserv' service so Windows Update picks up the change...
    [Info] Successfully restarted the 'wuauserv' service.
    [Info] Restarting the 'UsoSvc' service so Windows Update picks up the change...
    [Info] Successfully restarted the 'UsoSvc' service.

    [Info] Setting the custom field 'WSUSSettings' with the value:
    WSUS Status: Not Configured
    [Info] Successfully set the custom field 'WSUSSettings'.

    NOTE: the console output above shows the before/after (what was found, then that it was removed), while the custom field reflects only the end result of this run - "Not Configured" once the removal succeeded.

.EXAMPLE
    -RemoveWSUSSettings -ResetWindowsUpdateCache -TestWindowsUpdateConnectivity -CustomFieldName "WSUSSettings"

    [Info] Script Version: 1.12
    [Info] Checking the registry for WSUS settings...
    [Info] WSUS Update Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562
    [Info] WSUS Statistics Server detected in the registry: https://test.local.another.sub.domain/test/testagain:8562

    ### Active WSUS settings: ###

    WSUS Settings Source : Registry
    WSUS Status          : Enabled
    Update Server        : https://test.local.another.sub.domain/test/testagain:8562
    Statistics Server    : https://test.local.another.sub.domain/test/testagain:8562

    [Info] Testing connectivity to Windows Update endpoints...
    [Warning] Unable to reach ctldl.windowsupdate.com on port 80. This can indicate a firewall or proxy blocking Windows Update traffic.
    [Warning] Unable to reach download.windowsupdate.com on port 80. This can indicate a firewall or proxy blocking Windows Update traffic.
    [Info] Reachable: sls.update.microsoft.com:443
    [Info] Reachable: fe3.delivery.mp.microsoft.com:443
    [Info] Reachable: dl.delivery.mp.microsoft.com:80
    [Info] Reachable: geo.prod.do.dsp.mp.microsoft.com:443
    [Info] Reachable: tsfe.trafficshaping.dsp.mp.microsoft.com:443
    [Info] Reachable: adl.windows.com:80
    [Warning] 2 of 8 Windows Update endpoints could not be reached. If this device previously relied on WSUS exclusively, outbound firewall/proxy rules may need to be updated to allow direct access to Microsoft's update servers.

    [Info] Removing WSUS settings from the registry...
    [Info] Removing WSUS registry settings at 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'...
    [Info] Successfully removed WSUS registry settings at 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'.
    [Info] Restarting the 'wuauserv' service so Windows Update picks up the change...
    [Info] Successfully restarted the 'wuauserv' service.
    [Info] Restarting the 'bits' service so Windows Update picks up the change...
    [Info] Successfully restarted the 'bits' service.
    [Info] Restarting the 'UsoSvc' service so Windows Update picks up the change...
    [Info] Successfully restarted the 'UsoSvc' service.

    [Info] Resetting the Windows Update cache...
    [Info] Stopping the 'bits' service...
    [Info] Stopping the 'wuauserv' service...
    [Info] Stopping the 'cryptsvc' service...
    [Info] Stopping the 'UsoSvc' service...
    [Info] Renamed 'C:\Windows\SoftwareDistribution' to 'C:\Windows\SoftwareDistribution.bak_20260714120000'.
    [Info] Renamed 'C:\Windows\System32\catroot2' to 'C:\Windows\System32\catroot2.bak_20260714120000'.
    [Info] Starting the 'bits' service...
    [Info] Starting the 'wuauserv' service...
    [Info] Starting the 'cryptsvc' service...
    [Info] Starting the 'UsoSvc' service...

    [Info] Setting the custom field 'WSUSSettings' with the value:
    WSUS Status: Not Configured | WU Connectivity: 6/8 reachable | Cache Reset: Completed
    [Info] Successfully set the custom field 'WSUSSettings'.

.NOTES
    Minimum OS Architecture Supported: Windows 10, Windows Server 2016
    Version: 1.12
    Release Notes:
    - Fixed the custom field (and console) reporting "WSUS Status: Not Configured" on a device where the Windows Update Agent was clearly still bound to a WSUS service. The policy registry can read "Not Configured" while a *managed* WSUS registration lives in the agent's datastore - and that binding, not the empty policy key, is what a scan actually uses. The report now leads with an EFFECTIVE WSUS state ("Bound to service (<name>)" when a WSUS/third-party service is still bound, otherwise the policy state), and the previously separate, contradictory "Bound Non-MS Service" field is folded into that headline.
    - Added a domain-controller reachability check (Test-DomainControllerReachable via nltest /dsgetdc) reported as context only - it NEVER gates the remediation switches, so local cleanup still runs on a decommissioned-domain client. It appears in the console and as "DC: Reachable/Unreachable" in the custom field, and explains the common real-world cause (a roaming laptop off the corporate network/VPN, or a dead domain) for why a managed WSUS binding can't clear on a given run.
    - Corrected the guidance the script prints about a bound WSUS service. A *managed* WSUS binding does NOT clear by removing the registry settings or resetting the cache (the earlier "-ResetWindowsUpdateCache will clear it" advice was wrong); it clears only when the device completes a Group Policy cycle against a reachable domain controller with no WSUS configured, or when the device is removed from the domain. The -UnregisterStaleUpdateServices result is now reported as "Cleared" or "Blocked-NeedsDC/Domain" based on whether the binding is actually gone after the attempt, rather than on the COM call's return.
    - A managed WSUS service that can't be unregistered locally (the agent returns 0x8024801A) is now reported as a Warning and no longer sets a non-zero exit code / fails the whole NinjaOne action, since it's an environmental limitation (domain-managed) rather than a script error. -UnregisterStaleUpdateServices deliberately uses only non-blocking COM calls (RemoveService / AddService2) and never UnregisterServiceWithAU, which blocks trying to reach a decommissioned WSUS endpoint.
    - Added -UnregisterStaleUpdateServices (Ninja checkbox: unregisterStaleUpdateServices), the targeted fix for a WSUS service that stays bound to the Windows Update Agent as the DefaultAUService even after every WSUS registry value and GPO is gone. This state does NOT clear with -ResetWindowsUpdateCache: renaming SoftwareDistribution was confirmed in the field to leave the WSUS service registered and still the default, so the datastore is not where that binding lives. The new switch uses Microsoft.Update.ServiceManager.RemoveService to unregister each service the binding inspection flagged as a concern (falling back to registering Microsoft Update with AU first, then retrying, if the service refuses direct removal because AU treats it as the default), then restarts wuauserv/UsoSvc. After the action it re-audits the bound services and reports whether the WSUS binding is actually gone ("Cleared"), still present pending a reboot ("Reboot Pending"), or failed - both to the console and the custom field.
    - Fixed Reset-WindowsUpdateCache reporting "Cache Reset: Failed" (and failing the whole NinjaOne action) when only a service stop/start hiccupped while the cache folders actually renamed successfully. cryptsvc in particular frequently refuses to stop (dependent services / auto-restart) yet catroot2 still renames. Service stop/start problems are now warnings and no longer set the failure flag or exit code; only a genuine folder-rename failure marks the reset failed.
    - Fixed the NinjaOne custom field write failing with "Value length should be less than 200 characters" (which failed the entire action) when the assembled value exceeded the field's 200-character limit - the newly added Scan Blockers / Bound Non-MS Service fields could push a long applied-GPO list over the edge. The value is now truncated to 199 characters with an ellipsis, and the fields are appended in priority order (WSUS state, scan blockers, bound service, remediation results first; the verbose applied-GPO list last) so truncation drops the least actionable detail first.
    - Added a full-value inspection of the Windows Update policy key (Get-WindowsUpdatePolicyDiagnostics), run on every pass. The main WSUS check only reads UseWUServer/WUServer/WUStatusServer, but the same key can carry OTHER values that independently cause 0x80240438 ("no route or network connectivity to the endpoint") even when WSUS reports "Not Configured" - so a clean WSUS audit was hiding the value actually blocking the scan. It now enumerates every value under the key and its AU subkey and flags the known scan-blockers: DoNotConnectToWindowsUpdateInternetLocations, DisableWindowsUpdateAccess, DisableDualScan, the four SetPolicyDrivenUpdateSourceFor* Dual Scan overrides, and UseUpdateClassPolicySource (each only counted as a blocker when set non-zero). Blocker names are appended to the custom field as "Scan Blockers: ...".
    - Added an inspection of which update service the Windows Update Agent is actually bound to (Get-RegisteredUpdateServices via the Microsoft.Update.ServiceManager COM API), run on every pass. This binding lives in the agent's datastore (the SoftwareDistribution folder), NOT in the policy registry, so a WSUS service the agent registered years ago can remain the active scan source long after every WSUS registry value and GPO has been cleaned up - and keeps failing 0x80240438 against a server that no longer exists. Any service that isn't a known-Microsoft one (matched by service ID, including the well-known WSUS service ID 3da21691-e39d-4da6-8a4b-b43877bcb1b7) is flagged, along with its ServiceUrl and AU registration flags, with a pointer to -ResetWindowsUpdateCache as the fix. A stale binding is appended to the custom field as "Bound Non-MS Service: ...".
    - Both new checks are read-only and always run (no new Ninja checkbox), and are placed before the -RemoveWSUSSettings/-ResetWindowsUpdateCache actions so they report the pre-remediation state - i.e. what the removal and cache reset are about to clear.
    - Added -ResetWindowsUpdateCache (Ninja checkbox: resetWindowsUpdateCache), which follows Microsoft's documented manual reset procedure (stop BITS/wuauserv/cryptsvc, rename SoftwareDistribution and catroot2, restart the services): https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update. UsoSvc (Update Orchestrator) is stopped/started alongside them since it also holds update state in memory. Folders are renamed with a timestamp suffix rather than deleted, so a rollback is possible if needed. Deliberately does NOT perform the more aggressive legacy steps some public "WU reset" scripts include (re-registering WU/BITS DLLs via regsvr32, `netsh winsock reset`, resetting the BITS/wuauserv service ACLs via `sc.exe sdset`) - Microsoft's own guidance calls those a last resort only if the folder-rename step doesn't resolve the issue, they predate Windows 10's servicing model, and the ACL reset in particular is irreversible without a backup.
    - Added -TestWindowsUpdateConnectivity (Ninja checkbox: testWindowsUpdateConnectivity), which checks DNS resolution and TCP connectivity against 8 literal (non-wildcard) hostnames Microsoft documents across the Windows Update, Delivery Optimization, and Automatic Root Certificate Update endpoint families (ctldl.windowsupdate.com, download.windowsupdate.com, sls.update.microsoft.com, fe3.delivery.mp.microsoft.com, dl.delivery.mp.microsoft.com, geo.prod.do.dsp.mp.microsoft.com, tsfe.trafficshaping.dsp.mp.microsoft.com, adl.windows.com) - see https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/windows-update-issues-troubleshooting#device-cant-access-update-files. Most of Microsoft's published endpoints are wildcards (e.g. `*.windowsupdate.com`) and Microsoft doesn't publish IP ranges, so these are representative samples of each family rather than an exhaustive allowlist test. This targets the "environment was firewalled to only allow the old WSUS server" failure mode directly, since a device that's had its WSUS settings removed still needs a clear path to Microsoft's servers to resume scanning.
    - Added "bits" to the list of services restarted after -RemoveWSUSSettings succeeds, alongside the existing wuauserv/UsoSvc restart, since BITS can also hold a queued/in-progress download job pointed at the old WSUS server's URL.
    - Added -RemoveWSUSSettings (Ninja checkbox: removeWsusSettings) to delete the WSUS policy registry key after detection/reporting.
    - After a successful removal, restarts the wuauserv and UsoSvc services so the Windows Update Agent drops any WSUS endpoint it already had cached in memory instead of continuing to use it until the next reboot. Without this, a patch scan run immediately after removal could still fail trying to reach the now-deleted server (e.g. WU_E-style "no route or network connectivity to the endpoint" errors) even though the registry itself was already clean.
    - Removal now runs before the custom field is written, and the registry is re-checked afterward so the custom field reports the actual end result of the run (e.g. "Not Configured" after a successful removal) rather than the pre-removal snapshot. The console output still shows the full before/after detail; only the custom field was changed to reflect the final state. GPO Name / Applied GPOs attribution is still sourced from the pre-removal scan, since that context doesn't change based on whether the registry was just cleared.
    - Fixed GPO detection to always check the local Group Policy folder, even on servers (previously SYSVOL-only there), and to recognize a true Local Group Policy Object's Registry.pol (no domain GUID in its path) instead of discarding it as an invalid GPO ID. Without this, a Local GPO source was reported as "no GPOs found" and looked like an orphaned/tattooed registry setting.
    - Added Get-AppliedGPOs, which runs gpresult to capture every currently applied GPO, for cross-checking when the source doesn't trace back to a specific GPO from the Registry.pol scan. The full list is logged to the console; only entries whose name matches WSUS/Update/Patch are appended to the custom field, since NinjaOne text custom fields commonly cap out at 200 characters and the full applied-GPO list on a real box can easily exceed that.
    - GPO detection now also scans Group Policy Preferences Registry.xml files (not just Administrative Templates Registry.pol), since some GPOs (e.g. SBS-era "Update Services Common Settings" policies) push WSUS values via Preferences instead. A "D" (Delete) action on the WUServer item is treated as Disabled, matching the "**del." convention already used for Registry.pol.
    - Fixed a bug where a GPO deliberately pushing blank/nullified WUServer and WUStatusServer values (a common way to overwrite a stale tattooed address) caused $checkForGPOs to be reset to false, skipping the GPO search entirely even though UseWUServer still showed WSUS as actively policy-managed.
    - Added a "Script Version" line as the very first console output, so it's immediately obvious from a NinjaOne activity log which revision actually ran on that endpoint - useful for confirming a fix has actually been deployed versus the automation still running a stale cached copy.

    Imported from Ninja 4/15/2026 BBJr
    Modified to include removal of WSUS settings and GPOs in registry, Local GPO detection, and applied-GPO attribution reporting 7/8/2026 BBJr
    Modified to include Windows Update cache reset and Windows Update endpoint connectivity testing 7/14/2026 BBJr
    Modified to include full Windows Update policy-value inspection and registered update-service (datastore binding) inspection 7/22/2026 BBJr
    Modified to add -UnregisterStaleUpdateServices remediation, fix a false cache-reset failure on cryptsvc, and truncate the custom field to NinjaOne's 200-char limit 7/22/2026 BBJr
    Modified to report the EFFECTIVE WSUS state (bound managed service vs. policy), add DC-reachability context without gating remediation, and stop failing the action over a managed binding that can't be removed locally 7/22/2026 BBJr
#>

[CmdletBinding()]
param (
    [string]$CustomFieldName,
    [switch]$RemoveWSUSSettings,
    [switch]$ResetWindowsUpdateCache,
    [switch]$TestWindowsUpdateConnectivity,
    [switch]$UnregisterStaleUpdateServices
)
begin {
    # Keep in sync with the Version value in the comment-based help .NOTES block above.
    # Printed first so NinjaOne activity logs always show which revision of the script actually ran - useful when a fix doesn't seem to have taken effect on an endpoint.
    $ScriptVersion = "1.12"
    Write-Host -Object "[Info] Script Version: $ScriptVersion"

    # Import custom field from script variable
    if ($env:textCustomFieldName) { $CustomFieldName = $env:textCustomFieldName }

    # Import the "Remove WSUS Settings" checkbox from script variable
    if ($env:removeWsusSettings -eq "true") { $RemoveWSUSSettings = $true }

    # Import the "Reset Windows Update Cache" checkbox from script variable
    if ($env:resetWindowsUpdateCache -eq "true") { $ResetWindowsUpdateCache = $true }

    # Import the "Test Windows Update Connectivity" checkbox from script variable
    if ($env:testWindowsUpdateConnectivity -eq "true") { $TestWindowsUpdateConnectivity = $true }

    # Import the "Unregister Stale Update Services" checkbox from script variable
    if ($env:unregisterStaleUpdateServices -eq "true") { $UnregisterStaleUpdateServices = $true }

    # Validate the custom field name if provided
    if ($CustomFieldName) {
        # Trim the custom field name to remove any leading or trailing whitespace
        $CustomFieldName = $CustomFieldName.Trim()

        # Error if the custom field name is empty
        if ([string]::IsNullOrWhiteSpace($CustomFieldName)) {
            Write-Host -Object "[Error] The value for 'Text Custom Field Name' cannot be empty."
            Write-Host -Object "[Error] Please provide a valid text custom field name to save the results, or leave it blank."
            exit 1
        }

        # Validate that the field name contains only alphanumeric characters
        if ($CustomFieldName -match "[^0-9A-Z]") {
            Write-Host -Object "[Error] The 'Text Custom Field Name' of '$CustomFieldName' is invalid as it contains invalid characters."
            Write-Host -Object "[Error] Please provide a valid text custom field name to save the results, or leave it blank."
            Write-Host -Object "[Error] https://ninjarmm.zendesk.com/hc/en-us/articles/360060920631-Custom-Field-Setup"
            exit 1
        }
    }

    # Function to set a custom field in NinjaOne
    function Set-CustomField {
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $True)]
            [String]$Name,
            [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
            $Value,
            [Parameter()]
            [String]$Type,
            [Parameter()]
            [String]$DocumentName,
            [Parameter()]
            [Switch]$Piped
        )

        if ($Type -eq "Date Time") { $Type = "DateTime" }
        if ($Type -match "[-]") { $Type = $Type -replace '-' }
        if ($Type -match "[/]") { $Type = $Type -replace '/' }

        # Remove the non-breaking space character
        if ($Type -eq "WYSIWYG") {
            $Value = $Value -replace ' ', '&nbsp;'
        }

        if ($Type -eq "DateTime" -or $Type -eq "Date") {
            $Type = "Date or Date Time"
        }
    
        # Measure the number of characters in the provided value
        $Characters = $Value | ConvertTo-Json | Measure-Object -Character | Select-Object -ExpandProperty Characters

        # Throw an error if the value exceeds the character limit of 200,000 characters
        if ($Piped -and $Characters -ge 200000) {
            throw [System.ArgumentOutOfRangeException]::New("Character limit exceeded: the value is greater than or equal to 200,000 characters.")
        }

        if (!$Piped -and $Characters -ge 45000) {
            throw [System.ArgumentOutOfRangeException]::New("Character limit exceeded: the value is greater than or equal to 45,000 characters.")
        }
    
        # Initialize a hashtable for additional documentation parameters
        $DocumentationParams = @{}

        # If a document name is provided, add it to the documentation parameters
        if ($DocumentName) { $DocumentationParams["DocumentName"] = $DocumentName }
    
        # Define a list of valid field types
        $ValidFields = "Checkbox", "Date", "Date or Date Time", "DateTime", "Decimal", "Dropdown", "Email", "Integer", "IP Address", "MultiLine", 
        "MultiSelect", "Phone", "Secure", "Text", "Time", "URL", "WYSIWYG"

        # Warn the user if the provided type is not valid
        if ($Type -and $ValidFields -notcontains $Type) { Write-Warning "$Type is an invalid type. Please check here for valid types: https://ninjarmm.zendesk.com/hc/en-us/articles/16973443979789-Command-Line-Interface-CLI-Supported-Fields-and-Functionality" }
    
        # Define types that require options to be retrieved
        $NeedsOptions = "Dropdown", "MultiSelect"

        # If the property is being set in a document or field and the type needs options, retrieve them
        if ($DocumentName) {
            if ($NeedsOptions -contains $Type) {
                $NinjaPropertyOptions = Ninja-Property-Docs-Options -AttributeName $Name @DocumentationParams 2>&1
            }
        }
        else {
            if ($NeedsOptions -contains $Type) {
                $NinjaPropertyOptions = Ninja-Property-Options -Name $Name 2>&1
            }
        }
    
        # Throw an error if there was an issue retrieving the property options
        if ($NinjaPropertyOptions.Exception) { throw $NinjaPropertyOptions }
        
        # Process the property value based on its type
        switch ($Type) {
            "Checkbox" {
                # Convert the value to a boolean for Checkbox type
                $NinjaValue = [System.Convert]::ToBoolean($Value)
            }
            "Date or Date Time" {
                # Convert the value to a Unix timestamp for Date or Date Time type
                $Date = (Get-Date $Value).ToUniversalTime()
                $TimeSpan = New-TimeSpan (Get-Date "1970-01-01 00:00:00") $Date
                [long]$NinjaValue = $TimeSpan.TotalSeconds
            }
            "Dropdown" {
                # Convert the dropdown value to its corresponding GUID
                $Options = $NinjaPropertyOptions -replace '=', ',' | ConvertFrom-Csv -Header "GUID", "Name"
                $Selection = $Options | Where-Object { $_.Name -eq $Value } | Select-Object -ExpandProperty GUID
        
                # Throw an error if the value is not present in the dropdown options
                if (!($Selection)) {
                    throw [System.ArgumentOutOfRangeException]::New("Value is not present in dropdown options.")
                }
        
                $NinjaValue = $Selection
            }
            "MultiSelect" {
                $Options = $NinjaPropertyOptions -replace '=', ',' | ConvertFrom-Csv -Header "GUID", "Name"
                $Selections = New-Object System.Collections.Generic.List[String]
                if ($Value -match "[,]") {
                    $Value = $Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                }

                $Value | ForEach-Object {
                    $GivenValue = $_
                    $Selection = $Options | Where-Object { $_.Name -eq $GivenValue } | Select-Object -ExpandProperty GUID

                    # Throw an error if the value is not present in the dropdown options
                    if (!($Selection)) {
                        throw [System.ArgumentOutOfRangeException]::New("Value is not present in dropdown options.")
                    }

                    $Selections.Add($Selection)
                }

                $NinjaValue = $Selections -join ","
            }
            "Time" {
                # Convert the value to a Unix timestamp for Date or Date Time type
                $LocalTime = (Get-Date $Value)
                $LocalTimeZone = [TimeZoneInfo]::Local
                $UtcTime = [TimeZoneInfo]::ConvertTimeToUtc($LocalTime, $LocalTimeZone)

                [long]$NinjaValue = ($UtcTime.TimeOfDay).TotalSeconds
            }
            default {
                # For other types, use the value as is
                $NinjaValue = $Value
            }
        }
        
        # Set the property value in the document if a document name is provided
        if ($DocumentName) {
            $CustomField = Ninja-Property-Docs-Set -AttributeName $Name -AttributeValue $NinjaValue @DocumentationParams 2>&1
        }
        else {
            try {
                # Otherwise, set the standard property value
                if ($Piped) {
                    $CustomField = $NinjaValue | Ninja-Property-Set-Piped -Name $Name 2>&1
                }
                else {
                    $CustomField = Ninja-Property-Set -Name $Name -Value $NinjaValue 2>&1
                }
            }
            catch {
                throw $_.Exception.Message
            }
        }
        
        # Throw an error if setting the property failed
        if ($CustomField.Exception) {
            throw $CustomField
        }
    }

    # Function to remove the WSUS policy registry key
    function Remove-WSUSRegistrySettings {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $True)]
            [string]$Path
        )

        # If the key isn't present, there is nothing to remove
        if (!(Test-Path -Path $Path)) {
            Write-Host -Object "[Info] No WSUS registry settings were found at '$Path' to remove."
            return
        }

        try {
            Write-Host -Object "[Info] Removing WSUS registry settings at '$Path'..."
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Host -Object "[Info] Successfully removed WSUS registry settings at '$Path'."
        }
        catch {
            Write-Host -Object "[Error] Failed to remove WSUS registry settings at '$Path'."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            $script:ExitCode = 1
            return
        }

        # The Windows Update Agent can keep its update source cached in memory rather than reloading it as soon as the registry value disappears,
        # so restart the services that drive it to make sure it drops the stale (e.g. decommissioned WSUS) endpoint immediately instead of on the next reboot
        # bits is included alongside wuauserv/UsoSvc because it can also be holding a queued/in-progress download job pointed at the old WSUS server's URL
        foreach ($serviceName in "wuauserv", "bits", "UsoSvc") {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) { continue }

            try {
                Write-Host -Object "[Info] Restarting the '$serviceName' service so Windows Update picks up the change..."
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
                Write-Host -Object "[Info] Successfully restarted the '$serviceName' service."
            }
            catch {
                Write-Host -Object "[Warning] Failed to restart the '$serviceName' service."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }
        }
    }

    # Function to reset the Windows Update cache, following Microsoft's documented manual reset procedure:
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update
    # Deliberately does not perform the more aggressive steps from that article (regsvr32 re-registration of WU/BITS DLLs, netsh winsock reset, sc.exe sdset ACL reset) -
    # Microsoft calls those a last resort only if the folder rename doesn't help, they're carried over from pre-Windows 10 troubleshooting, and the ACL reset can't be undone without a backup
    function Reset-WindowsUpdateCache {
        [CmdletBinding()]
        param ()

        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $success = $true

        # These three are the services Microsoft's own reset guidance stops before renaming the cache folders.
        # UsoSvc (Update Orchestrator) is included too since it holds update state in memory, same reasoning as the service restart after -RemoveWSUSSettings above
        $servicesToCycle = "bits", "wuauserv", "cryptsvc", "UsoSvc"

        foreach ($serviceName in $servicesToCycle) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) { continue }

            try {
                Write-Host -Object "[Info] Stopping the '$serviceName' service..."
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }
            catch {
                # A service that won't stop (cryptsvc is the usual culprit - other services depend on it, or it auto-restarts) is not by itself
                # fatal: the folder rename below often still succeeds. Treat it as a warning and let the rename result decide overall success,
                # rather than failing the whole reset (and the NinjaOne action) over a service that didn't need to be down for the rename to work.
                Write-Host -Object "[Warning] Could not stop the '$serviceName' service; continuing. If a cache folder fails to rename below, this is the likely cause."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }
        }

        # Renaming (rather than deleting) preserves the option to roll back, and matches Microsoft's own documented reset steps
        $foldersToRename = @(
            [PSCustomObject]@{ Path = "$env:SystemRoot\SoftwareDistribution"; NewName = "SoftwareDistribution.bak_$timestamp" }
            [PSCustomObject]@{ Path = "$env:SystemRoot\System32\catroot2"; NewName = "catroot2.bak_$timestamp" }
        )

        foreach ($folder in $foldersToRename) {
            if (!(Test-Path -Path $folder.Path)) {
                Write-Host -Object "[Info] '$($folder.Path)' does not exist; nothing to rename."
                continue
            }

            try {
                Rename-Item -Path $folder.Path -NewName $folder.NewName -ErrorAction Stop
                Write-Host -Object "[Info] Renamed '$($folder.Path)' to '$(Join-Path -Path (Split-Path -Path $folder.Path -Parent) -ChildPath $folder.NewName)'."
            }
            catch {
                Write-Host -Object "[Error] Failed to rename '$($folder.Path)'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $script:ExitCode = 1
                $success = $false
            }
        }

        foreach ($serviceName in $servicesToCycle) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) { continue }

            try {
                Write-Host -Object "[Info] Starting the '$serviceName' service..."
                Start-Service -Name $serviceName -ErrorAction Stop
            }
            catch {
                # These services are demand/trigger-start; Windows brings them back automatically on the next update operation. Don't fail the
                # reset over a start hiccup - the cache rename (the actual point of the reset) is what determines success.
                Write-Host -Object "[Warning] Could not start the '$serviceName' service; Windows will start it on demand at the next update operation."
                Write-Host -Object "[Warning] $($_.Exception.Message)"
            }
        }

        return $success
    }

    # Function to test DNS resolution and TCP connectivity to a representative sample of Microsoft's published Windows Update / Delivery Optimization / Automatic Root
    # Certificate Update endpoints. Most of the endpoints Microsoft documents are wildcards (e.g. *.windowsupdate.com) and Microsoft doesn't publish IP ranges for them,
    # so these are literal, non-wildcard hostnames confirmed live and drawn from:
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/windows-update-issues-troubleshooting#device-cant-access-update-files
    # https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/privacy/manage-windows-2004-endpoints
    function Test-WindowsUpdateConnectivity {
        [CmdletBinding()]
        param ()

        $endpoints = @(
            [PSCustomObject]@{ Hostname = "ctldl.windowsupdate.com"; Port = 80 }
            [PSCustomObject]@{ Hostname = "download.windowsupdate.com"; Port = 80 }
            [PSCustomObject]@{ Hostname = "sls.update.microsoft.com"; Port = 443 }
            [PSCustomObject]@{ Hostname = "fe3.delivery.mp.microsoft.com"; Port = 443 }
            [PSCustomObject]@{ Hostname = "dl.delivery.mp.microsoft.com"; Port = 80 }
            [PSCustomObject]@{ Hostname = "geo.prod.do.dsp.mp.microsoft.com"; Port = 443 }
            [PSCustomObject]@{ Hostname = "tsfe.trafficshaping.dsp.mp.microsoft.com"; Port = 443 }
            [PSCustomObject]@{ Hostname = "adl.windows.com"; Port = 80 }
        )

        foreach ($endpoint in $endpoints) {
            $dnsResolved = $false
            $tcpConnected = $false

            try {
                $null = Resolve-DnsName -Name $endpoint.Hostname -ErrorAction Stop
                $dnsResolved = $true
            }
            catch {
                # A DNS failure here corresponds to WU_E_PT_WINHTTP_NAME_NOT_RESOLVED (0x8024402C) and usually points to a DNS server or proxy PAC issue rather than a firewall block
            }

            if ($dnsResolved) {
                try {
                    $tcpClient = [System.Net.Sockets.TcpClient]::new()
                    $connectTask = $tcpClient.ConnectAsync($endpoint.Hostname, $endpoint.Port)
                    $tcpConnected = $connectTask.Wait(5000) -and $tcpClient.Connected
                    $tcpClient.Close()
                }
                catch {
                    $tcpConnected = $false
                }
            }

            [PSCustomObject]@{
                Hostname     = $endpoint.Hostname
                Port         = $endpoint.Port
                DNSResolved  = $dnsResolved
                TCPConnected = $tcpConnected
            }
        }
    }

    # Function to retrieve the list of Group Policy Objects currently applied to this computer via gpresult
    # Used for attribution/troubleshooting when the WSUS registry settings can't be traced back to a specific GPO from the Registry.pol scan (e.g. tattooed values, Group Policy Preferences, or a GPO from a decommissioned domain controller)
    function Get-AppliedGPOs {
        [CmdletBinding()]
        param ()

        try {
            $gpresultOutput = & "$env:SystemRoot\System32\gpresult.exe" /r /scope:computer 2>&1
        }
        catch {
            Write-Host -Object "[Error] Failed to run 'gpresult.exe'."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            return $null
        }

        $capturing = $false
        $appliedGPOs = New-Object System.Collections.Generic.List[string]

        foreach ($line in $gpresultOutput) {
            if (-not $capturing) {
                # Look for the start of the "Applied Group Policy Objects" section
                if ($line -match "^\s*Applied Group Policy Objects\s*$") {
                    $capturing = $true
                }
                continue
            }

            # A blank line marks the end of the section
            if ([string]::IsNullOrWhiteSpace($line)) {
                break
            }

            # Skip the dashed underline directly beneath the section header
            if ($line -match "^\s*-+\s*$") {
                continue
            }

            $appliedGPOs.Add($line.Trim())
        }

        if ($appliedGPOs.Count -eq 0) {
            return $null
        }

        return $appliedGPOs
    }

    # Function to enumerate ALL values under the Windows Update policy key and its AU subkey, and flag the ones known to block or redirect a scan.
    # The main WSUS check only inspects UseWUServer/WUServer/WUStatusServer, but several OTHER policy values in this same key can independently
    # cause "There is no route or network connectivity to the endpoint" (0x80240438) even when no WSUS server address is set - most commonly the
    # Dual Scan overrides that force an intranet/managed scan source, or a policy that blocks access to Windows Update on the internet entirely.
    # This is exactly the case a "WSUS is Not Configured" audit hides: the key still exists and still carries a value that stops the scan.
    function Get-WindowsUpdatePolicyDiagnostics {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $True)]
            [string]$Path
        )

        if (!(Test-Path -Path $Path)) {
            return $null
        }

        # Value names known to redirect the scan to a (now-missing) intranet source, or to block the internet path, when present and non-zero.
        # Keyed by the friendly description shown when the value is a blocker.
        $blockingValues = [ordered]@{
            "DoNotConnectToWindowsUpdateInternetLocations" = "Blocks the device from contacting Windows Update on the internet (it may only use an intranet WSUS server, which no longer exists)."
            "DisableWindowsUpdateAccess"                   = "Removes access to all Windows Update features, which prevents the agent from scanning."
            "DisableDualScan"                              = "Forces scanning against the configured intranet/WSUS source only, blocking the fallback to Windows Update on the internet."
            "SetPolicyDrivenUpdateSourceForFeatureUpdates" = "Forces feature updates to come from the intranet/WSUS source only."
            "SetPolicyDrivenUpdateSourceForQualityUpdates" = "Forces quality updates to come from the intranet/WSUS source only."
            "SetPolicyDrivenUpdateSourceForDriverUpdates"  = "Forces driver updates to come from the intranet/WSUS source only."
            "SetPolicyDrivenUpdateSourceForOtherUpdates"   = "Forces other updates to come from the intranet/WSUS source only."
            "UseUpdateClassPolicySource"                   = "Enables the per-update-class scan source policies above."
        }

        $findings = New-Object System.Collections.Generic.List[object]

        foreach ($subPath in $Path, "$Path\AU") {
            if (!(Test-Path -Path $subPath)) { continue }

            $props = Get-ItemProperty -Path $subPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }

            # Enumerate the actual value names present under the key, excluding PowerShell's PS* housekeeping properties
            $valueNames = ($props.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS(Path|ParentPath|ChildName|Provider|Drive)$" }).Name

            foreach ($valueName in $valueNames) {
                $value = $props.$valueName

                # Only treat a known value as a blocker when it's actually enabled (non-zero); a value explicitly set to 0 is benign
                $isBlocker = $blockingValues.Contains($valueName) -and $value -ne 0

                $findings.Add([PSCustomObject]@{
                    Key         = $subPath
                    Name        = $valueName
                    Value       = $value
                    IsBlocker   = $isBlocker
                    Explanation = if ($isBlocker) { $blockingValues[$valueName] } else { $null }
                })
            }
        }

        return $findings
    }

    # Function to enumerate the update services the Windows Update Agent is actually bound to. This state lives in the agent's datastore
    # (the SoftwareDistribution folder), NOT in the policy registry key, so a WSUS service the agent registered years ago can remain the
    # active scan source long after every WSUS *policy* value has been removed - producing 0x80240438 against an endpoint that no longer
    # exists. Renaming SoftwareDistribution (-ResetWindowsUpdateCache) is what clears it; this surfaces whether that reset is still needed.
    function Get-RegisteredUpdateServices {
        [CmdletBinding()]
        param ()

        # Well-known Microsoft service IDs, so anything else can be flagged as a WSUS/third-party source.
        # 3da21691-... is the "Windows Server Update Service" (WSUS) service ID - its presence is the direct sign of a WSUS binding.
        $knownServices = @{
            "9482f4b4-e343-43b6-b170-9a65bc822c77" = "Windows Update"
            "7971f918-a847-4430-9279-4a52d1efe18d" = "Microsoft Update"
            "855e8a7c-ecb4-4ca3-b045-1dfa50104289" = "Windows Store"
            "117cab2d-82b1-4b5a-a08c-4d62dbee7782" = "Windows Store (DCat Prod)"
            "3da21691-e39d-4da6-8a4b-b43877bcb1b7" = "Windows Server Update Service (WSUS)"
        }

        try {
            $serviceManager = New-Object -ComObject "Microsoft.Update.ServiceManager"
        } catch {
            Write-Host -Object "[Warning] Unable to query the Windows Update service manager (Microsoft.Update.ServiceManager)."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
            return $null
        }

        $services = foreach ($service in $serviceManager.Services) {
            # ServiceUrl / IsDefaultAUService come from IUpdateService2 (available on the script's minimum supported OS); guard each access anyway
            # so one service that doesn't expose a property can't abort the whole enumeration
            $serviceId = "$($service.ServiceID)".ToLower()
            $serviceUrl = try { $service.ServiceUrl } catch { $null }
            $isDefaultAU = try { [bool]$service.IsDefaultAUService } catch { $false }
            $isRegisteredAU = [bool]$service.IsRegisteredWithAU

            # A Microsoft-hosted service URL lives under one of these domains. A WSUS binding instead points at an intranet host (e.g. http://sbs:8530).
            # We test the URL rather than allowlisting service IDs, since Microsoft ships several background services (DCat, Store, flighting) whose
            # IDs vary across builds - flagging by "not a known ID" would produce false positives on a perfectly healthy device.
            $isMicrosoftUrl = [string]::IsNullOrWhiteSpace($serviceUrl) -or $serviceUrl -match "(?i)\.(microsoft\.com|windowsupdate\.com|windows\.com)(/|:|$)"

            # A service is the actual scan source only if AU is bound to it. That plus the WSUS service ID, or an AU-bound service with a
            # non-Microsoft URL, is the signal that a stale WSUS/third-party source is what a scan is still failing against.
            $isAUBound = $isDefaultAU -or $isRegisteredAU
            $isConcern = ($serviceId -eq "3da21691-e39d-4da6-8a4b-b43877bcb1b7") -or ($isAUBound -and -not $isMicrosoftUrl)

            [PSCustomObject]@{
                Name               = $service.Name
                ServiceID          = $serviceId
                KnownName          = $knownServices[$serviceId]
                IsDefaultAUService = $isDefaultAU
                IsRegisteredWithAU = $isRegisteredAU
                IsManaged          = [bool]$service.IsManaged
                ServiceUrl         = $serviceUrl
                IsWSUS             = $serviceId -eq "3da21691-e39d-4da6-8a4b-b43877bcb1b7"
                IsConcern          = $isConcern
            }
        }

        return $services
    }

    # Function to unregister a stale WSUS / third-party update service from the Windows Update Agent via the Microsoft.Update.ServiceManager COM API.
    # This is the targeted remediation for the case Get-RegisteredUpdateServices surfaces: the WSUS service is still registered - and still the
    # DefaultAUService - even though every WSUS registry value and GPO is gone. Renaming SoftwareDistribution (-ResetWindowsUpdateCache) does NOT
    # clear this, because the service registration and the default-AU-service selection persist outside that folder. Removing the WSUS service
    # makes the agent fall back to the built-in Windows Update service as its default, which is what a scan failing 0x80240438 needs.
    function Remove-StaleUpdateServiceRegistration {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $True)]
            [object[]]$Services
        )

        try {
            $serviceManager = New-Object -ComObject "Microsoft.Update.ServiceManager"
            $serviceManager.ClientApplicationID = "Check for WSUS Settings and remove.ps1"
        } catch {
            Write-Host -Object "[Error] Unable to create the Windows Update service manager to unregister stale services."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            $script:ExitCode = 1
            return $false
        }

        # Microsoft Update (includes Office and other Microsoft products, and is the source a patch-management scan usually expects) - registering
        # it with AU establishes a valid non-WSUS default. Flags 7 = asfAllowPendingRegistration + asfAllowOnlineRegistration + asfRegisterServiceWithAU.
        $microsoftUpdateId = "7971f918-a847-4430-9279-4a52d1efe18d"

        $allRemoved = $true

        foreach ($svc in $Services) {
            try {
                Write-Host -Object "[Info] Unregistering stale update service '$($svc.Name)' (ServiceID $($svc.ServiceID))..."
                $serviceManager.RemoveService($svc.ServiceID)
                Write-Host -Object "[Info] Successfully unregistered '$($svc.Name)'."
            } catch {
                # A service AU currently treats as the default can refuse direct removal. Establish Microsoft Update as an AU-registered default
                # first (which displaces WSUS as the default service), then retry the removal once.
                Write-Host -Object "[Warning] Direct removal of '$($svc.Name)' failed; registering Microsoft Update with Automatic Updates first, then retrying."
                Write-Host -Object "[Warning] $($_.Exception.Message)"

                try {
                    $null = $serviceManager.AddService2($microsoftUpdateId, 7, "")
                    Write-Host -Object "[Info] Registered Microsoft Update with Automatic Updates."
                } catch {
                    Write-Host -Object "[Warning] Failed to register Microsoft Update with Automatic Updates: $($_.Exception.Message)"
                }

                try {
                    $serviceManager.RemoveService($svc.ServiceID)
                    Write-Host -Object "[Info] Successfully unregistered '$($svc.Name)' on retry."
                } catch {
                    # A *managed* WSUS service can't be removed locally while the device is domain-joined - the agent returns 0x8024801A
                    # (invalid operation) because it won't deregister the managed default service. That's an environmental limitation, not a
                    # script failure, so report it as a warning WITHOUT failing the whole action; the post-remediation re-audit and the custom
                    # field make the remaining binding explicit, and the console explains the DC/domain requirement to clear it.
                    Write-Host -Object "[Warning] Could not unregister '$($svc.Name)' locally: $($_.Exception.Message)"
                    Write-Host -Object "[Warning] This is expected for a managed WSUS binding on a domain-joined device - it clears via a Group Policy cycle against a reachable domain controller, or by removing the device from the domain."
                    $allRemoved = $false
                }
            }
        }

        # Restart the agent so it re-reads its (now WSUS-free) service list and settles on the built-in default immediately, rather than on the next reboot
        foreach ($serviceName in "wuauserv", "UsoSvc") {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) { continue }

            try {
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
            }
            catch {
                Write-Host -Object "[Warning] Could not restart the '$serviceName' service after unregistering; a reboot will finish applying the change."
            }
        }

        return $allRemoved
    }

    # Function to quickly test whether a live domain controller for this machine's domain is currently reachable.
    # Used purely as REPORTING CONTEXT - it never gates the remediation switches (an operator cleaning up a dead-domain client
    # must still be able to run them). It explains whether a stale *managed* WSUS binding can be expected to clear on this run,
    # since that requires a successful Group Policy cycle against a DC (or the device being removed from the domain).
    function Test-DomainControllerReachable {
        [CmdletBinding()]
        param ()

        try {
            $domain = (Get-CimInstance -Class Win32_ComputerSystem -ErrorAction Stop).Domain
        } catch {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($domain)) { return $false }

        try {
            # nltest /dsgetdc locates a DC for the domain; a zero exit code means one answered
            $null = & "$env:SystemRoot\System32\nltest.exe" "/dsgetdc:$domain" 2>&1
            return ($LASTEXITCODE -eq 0)
        } catch {
            return $false
        }
    }

    # Function to test if a device is domain-joined
    function Test-IsDomainJoined {
        # Check the PowerShell version to determine the appropriate cmdlet to use
        try {
            if ($PSVersionTable.PSVersion.Major -lt 3) {
                return $(Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
            }
            else {
                return $(Get-CimInstance -Class Win32_ComputerSystem).PartOfDomain
            }
        }
        catch {
            Write-Host -Object "[Error] Unable to validate whether or not this device is a part of a domain."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }
    }

    # Function to test if the current device is a server or domain controller
    function Test-IsServer {
        [CmdletBinding()]
        param()
    
        # Determine the method to retrieve the operating system information based on PowerShell version
        $OS = if ($PSVersionTable.PSVersion.Major -lt 3) {
            Get-WmiObject -Class Win32_OperatingSystem
        }
        else {
            Get-CimInstance -ClassName Win32_OperatingSystem
        }
    
        # Check if the ProductType is "2", which indicates that the system is a domain controller or is a server
        if ($OS.ProductType -eq "2" -or $OS.ProductType -eq "3") {
            return $true
        }
    }

    # Function to test if the current session is running with Administrator privileges
    function Test-IsElevated {
        [CmdletBinding()]
        param ()
    
        # Get the current Windows identity of the user running the script
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    
        # Create a WindowsPrincipal object based on the current identity
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    
        # Check if the current user is in the Administrator role
        # The function returns $True if the user has administrative privileges, $False otherwise
        # 544 is the value for the Built In Administrators role
        # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsbuiltinrole
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]'544')
    }
}
process {
    # Attempt to determine if the current session is running with Administrator privileges.
    try {
        $IsElevated = Test-IsElevated -ErrorAction Stop
    } catch {
        # Output error if unable to determine elevation status
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running with Administrator privileges."
        exit 1
    }

    # Exit if not running as an administrator
    if (!$IsElevated) {
        Write-Host -Object "[Error] Access Denied: Please run with Administrator privileges."
        exit 1
    }

    # Check if the device is domain-joined
    $IsDomainJoined = Test-IsDomainJoined

    # If domain-joined, do a group policy update
    if ($IsDomainJoined) {
        # Run gpupdate to ensure policy is refreshed
        Write-Host -Object "[Info] Updating group policies..."

        # Generate unique log file names for capturing the stdout and stderr of the 'gpupdate.exe' process.
        $StandardOutLog = "$env:TEMP\$(Get-Random)_gpupdate_stdout.log"

        try {
            # Start the group policy update process
            $gpupdateProcess = Start-Process -FilePath "$env:SystemRoot\System32\gpupdate.exe" -ArgumentList "/force" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $StandardOutLog -ErrorAction Stop
        } catch {
            # If the 'gpupdate.exe' process fails to start, output an error message
            Write-Host -Object "[Error] $($_.Exception.Message)"
            Write-Host -Object "[Error] Failed to start '$env:SystemRoot\System32\gpupdate.exe'."
        }

        # If the exit code is non-zero (indicating an error occurred), display an error message
        if ($gpupdateProcess.ExitCode -ne 0) {
            Write-Host -Object "[Error] Failed to update group policy, exit code: $($gpupdateProcess.ExitCode)"

            # Check if the standard output log file exists.
            if (Test-Path -Path $StandardOutLog -ErrorAction SilentlyContinue) {
                # Retrieve the contents of the error log
                $errorContent = Get-Content -Path $StandardOutLog -ErrorAction SilentlyContinue
                
                if ($ErrorContent) {
                    # Remove blank lines and the header of the log
                    $errorContent = $errorContent | Where-Object { $_ } | Select-Object -Skip 1 | Out-String

                    # Add [Error] prefix to the beginning
                    $errorContent = $errorContent.Trim() -replace "^", "[Error] "
                    
                    # Display the error content to the user
                    $errorContent | Out-Host
                }

                try {
                    # Attempt to delete the stdout log file after displaying its contents.
                    Remove-Item -Path $StandardOutLog -ErrorAction Stop
                } catch {
                    Write-Host -Object "[Error] Failed to remove standard output log at '$StandardOutLog'"
                }
            }
            Write-Host -Object ""
            Write-Host -Object "[Warning] Failed to update group policy. Results may not reflect the latest group policy settings."
        } else {
            Write-Host -Object "[Info] Group policy update completed successfully."
        }
    }

    # Determine whether a domain controller is currently reachable. This is REPORTING CONTEXT ONLY - it never gates the remediation
    # switches below, so an operator cleaning up a decommissioned-domain client can still run them. It explains whether a stale
    # *managed* WSUS binding can be expected to clear on this run: clearing one requires a Group Policy cycle against a reachable DC,
    # or the device leaving the domain. Common "unreachable" cases: a roaming laptop off the corporate network/VPN, or a dead domain.
    $DomainControllerReachable = $null
    if ($IsDomainJoined) {
        $DomainControllerReachable = Test-DomainControllerReachable
        if ($DomainControllerReachable) {
            Write-Host -Object "`n[Info] A domain controller is reachable for this device's domain."
        } else {
            Write-Host -Object "`n[Warning] No domain controller is reachable for this device's domain (e.g. a roaming laptop off the corporate network/VPN, or a decommissioned domain). Group Policy cannot process, so a stale *managed* WSUS binding cannot be cleared on this run - but registry/policy cleanup and every requested action below still run normally."
        }
    }

    # Initialize exit code and output object
    $ExitCode = 0
    $ActiveWSUSSettings = [PSCustomObject]::new()

    # Define registry path for WSUS settings
    $wsusRegPath = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'

    # Check registry for WSUS settings
    if ((Test-Path $wsusRegPath)) {
        Write-Host -Object "`n[Info] Checking the registry for WSUS settings..."

        try {
            $useWUServer = (Get-ItemProperty -Path "$wsusRegPath\AU" -ErrorAction Stop).UseWUServer
        } catch {
            Write-Host -Object "`n[Error] Error retrieving WSUS settings from the registry."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }

        # Add registry as the source to the active settings object
        $ActiveWSUSSettings | Add-Member -MemberType NoteProperty -Name "WSUS Settings Source" -Value "Registry"

        # If the GPO setting is configured, the UseWUServer regkey will be present and populated
        switch ($useWUServer) {
            0 {
                $checkForGPOs = $true
                $WSUSStatus = "Disabled"
            }
            1 {
                $checkForGPOs = $true
                $WSUSStatus = "Enabled"
            }
            default {
                # If the UseWUServer regkey is not present or is a different value, it means WSUS is not configured via GPO, so we can skip checking for GPOs
                $checkForGPOs = $false
                $WSUSStatus = "Not Configured"
                Write-Host -Object "[Info] WSUS is not enabled on this device."
            }
        }

        # Add the WSUS status to the active settings object
        $ActiveWSUSSettings | Add-Member -MemberType NoteProperty -Name "WSUS Status" -Value $WSUSStatus
        
        # Retrieve the WSUS server and statistics server from the registry
        $wsusServerReg = Get-ItemProperty -Path "$wsusRegPath" -Name WUServer, WUStatusServer -ErrorAction SilentlyContinue
        $wsusServerFromRegistry = $wsusServerReg.WUServer
        $statisticsServerFromRegistry = $wsusServerReg.WUStatusServer
        
        # If either server is configured, add the servers to the active settings object and check for GPOs
        if ($wsusServerFromRegistry -or $statisticsServerFromRegistry) {
            $checkForGPOs = $true
            $ActiveWSUSSettings."WSUS Settings Source" = "Registry"

            if ($wsusServerFromRegistry) {
                Write-Host -Object "[Info] WSUS Update Server detected in the registry: $wsusServerFromRegistry"
            } else {
                $wsusServerFromRegistry = "Not Configured"
                Write-Host -Object "[Warning] The WSUS Update Server is not configured. The update server is required for WSUS to function correctly."
            }

            if ($statisticsServerFromRegistry) {
                Write-Host -Object "[Info] WSUS Statistics Server detected in the registry: $statisticsServerFromRegistry"
            } else {
                $statisticsServerFromRegistry = "Not Configured"
                Write-Host -Object "[Warning] The WSUS Statistics Server is not configured. The statistics server is required for WSUS to function correctly."
            }
        } else {
            # Neither server string is populated. This does NOT necessarily mean WSUS isn't policy-managed - a GPO may deliberately push blank/nullified server values
            # (e.g. to overwrite a stale tattooed address) while UseWUServer is still 0 or 1, so leave $checkForGPOs as the switch above already determined it
            $wsusServerFromRegistry = "Not Configured"
            $statisticsServerFromRegistry = "Not Configured"
            Write-Host -Object "[Warning] No WSUS servers were detected in the registry."
        }

        # Add the WSUS server and statistics server to the active settings object
        $ActiveWSUSSettings | Add-Member -MemberType NoteProperty -Name "Update Server" -Value $wsusServerFromRegistry
        $ActiveWSUSSettings | Add-Member -MemberType NoteProperty -Name "Statistics Server" -Value $statisticsServerFromRegistry
    }
    else {
        $checkForGPOs = $false
        Write-Host -Object "`n[Info] The registry key '$wsusRegPath' was not found. WSUS is not configured on this device.`n"
    }

    # Check for GPO setting the WSUS configuration
    if ($IsDomainJoined -and $checkForGPOs) {
        Write-Host -Object "`n[Info] Checking for GPOs that configure WSUS settings..."

        # Define the WSUS registry path
        $wsusRegistryPath = "Software\\Policies\\Microsoft\\Windows\\WindowsUpdate"

        # Get the domain name
        try {
            $domainName = (Get-CimInstance -Class Win32_ComputerSystem -ErrorAction Stop).Domain
        } catch {
            Write-Host -Object "[Error] Failed to retrieve the domain name."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            exit 1
        }

        # Define the GPO paths to search for Registry.pol files
        # Always check the local Group Policy folders, since these hold the resultant applied policy for BOTH domain GPOs and true Local Group Policy Objects (gpedit.msc)
        # A Local GPO applies independently of AD and will silently re-tattoo the registry on every gpupdate, so it must be checked on servers too, not just SYSVOL
        $gpoFolderPaths = @(
            "$env:windir\System32\GroupPolicy\"
            "$env:windir\System32\GroupPolicyUsers\"
        )

        # Also check SYSVOL so domain GPOs can be resolved to their display name, since Test-IsServer machines don't always cache a local per-GPO copy
        if (Test-IsServer) {
            $gpoFolderPaths += "\\$domainName\SYSVOL\$domainName\Policies\"
        }

        # Search for WSUS settings in both Administrative Templates (Registry.pol) and Group Policy Preferences (Registry.xml) files
        # SBS-era GPOs in particular often push WSUS settings via Preferences rather than Administrative Templates
        $gposAffectingWSUS = foreach ($folderPath in $gpoFolderPaths) {
            $policyFiles = Get-ChildItem -Path $folderPath -Include "Registry.pol", "Registry.xml" -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable registryPolFileErrors

            foreach ($errorInstance in $registryPolFileErrors) {
                Write-Host -Object "[Error] Error encountered while retrieving policy files from '$folderPath'."
                Write-Host -Object "[Error] $($errorInstance.Exception.Message)"
                $ExitCode = 1
            }

            # For each policy file found, read its contents and check for WSUS settings
            foreach ($polFile in $policyFiles) {
                $isPreference = $polFile.Extension -eq ".xml"

                # Read the contents of the file. Registry.pol is UTF-16 with embedded nulls between characters; Registry.xml (GPP) is plain XML
                $polContent = (Get-Content -Path $polFile.FullName -ErrorAction SilentlyContinue | Out-String) -replace "`0"

                # If the content of the file contains the WSUS registry path, extract the settings
                if ($polContent -match $wsusRegistryPath) {
                    # Extract the GPO ID from the file path (matches both "...\Machine\Registry.pol" and "...\Machine\Preferences\Registry\Registry.xml")
                    $GPOId = $polFile.FullName -replace ".*\\Policies\\(.*?)\\Machine\\.*", '$1'

                    # If the GPO ID is not in the expected format, this may be the true Local Group Policy Object instead of a domain GPO
                    if ($GPOId -notmatch "{\w{8}-\w{4}-\w{4}-\w{4}-\w{12}}") {
                        if ($polFile.FullName -like "$env:windir\System32\GroupPolicy\Machine\*") {
                            $GPOId = "Local Group Policy"
                        } else {
                            Write-Host -Object "[Error] Invalid GPO ID format found in $($polFile.FullName): $GPOId"
                            $ExitCode = 1
                            continue
                        }
                    }

                    if ($isPreference) {
                        # Parse the Group Policy Preferences Registry.xml item(s) for the WSUS values
                        try {
                            $registryXml = [xml]$polContent
                        } catch {
                            Write-Host -Object "[Error] Failed to parse '$($polFile.FullName)' as XML."
                            Write-Host -Object "[Error] $($_.Exception.Message)"
                            $ExitCode = 1
                            continue
                        }

                        $wuServerItem = $registryXml.SelectNodes("//Registry/Properties") | Where-Object { $_.name -eq "WUServer" } | Select-Object -First 1
                        $wuStatusServerItem = $registryXml.SelectNodes("//Registry/Properties") | Where-Object { $_.name -eq "WUStatusServer" } | Select-Object -First 1

                        # A "D" (Delete) action removes the value from the registry - the Preferences equivalent of disabling WSUS via this GPO
                        if ($wuServerItem.action -eq "D") {
                            $GPOStatus = "Disabled"
                        } else {
                            $GPOStatus = "Enabled"
                        }

                        $WUServer = $wuServerItem.value
                        $WUStatisticsServer = $wuStatusServerItem.value
                    } else {
                        # Define a regex pattern for capturing the WSUS settings from the Registry.pol file
                        $regexPattern = "(?<disable>\*\*del\.)?WUServer;(.+?;){2}(?<UpdateServer>.+?)].+?WUStatusServer;(.+?;){2}(?<StatisticsServer>.+?)]"

                        # Use regex to match the WSUS settings
                        $regexMatches = [regex]::Match($polContent, $regexPattern)

                        # Check if GPO is disabling or enabling WSUS
                        if ($regexMatches.Groups['disable'].Value) {
                            $GPOStatus = "Disabled"
                        } else {
                            $GPOStatus = "Enabled"
                        }

                        # Extract the servers
                        $WUServer = $regexMatches.Groups['UpdateServer'].Value
                        $WUStatisticsServer = $regexMatches.Groups['StatisticsServer'].Value
                    }

                    # Create a custom object with the GPO ID and WSUS settings
                    [PSCustomObject]@{
                        Id               = $GPOId
                        GPOStatus        = $GPOStatus
                        UpdateServer     = $WUServer
                        StatisticsServer = $WUStatisticsServer
                    }
                }
            }
        }
        
        # If GPOs were found that affect WSUS settings, filter them to only include those that are active
        if ($gposAffectingWSUS) {
            # Define the registry path to currently applied GPOs that use Administrative Templates
            $gpoHistoryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Group Policy\History\{35378EAC-683F-11D2-A89A-00C04FBBCFA2}"
            
            # Retrieve active GPOs on this device from the registry path
            try {
                $activeGPOs = Get-ChildItem -Path $gpoHistoryPath -ErrorAction Stop | ForEach-Object { Get-ItemProperty -Path $_.PSPath -Name DisplayName, GPOName -ErrorAction Stop }
            } catch {
                Write-Host -Object "[Error] Failed to retrieve active GPOs from the registry."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                exit 1
            }

            # Filter the GPOs that affect WSUS settings to only include those that are active
            # A Local Group Policy Object is always considered active since it was read directly from the live, currently-applied Registry.pol file
            $gposAffectingWSUS = $gposAffectingWSUS | Where-Object { $_.Id -eq "Local Group Policy" -or $_.Id -in $activeGPOs.GPOName }
        }

        # If any active GPOs are found that affect WSUS settings, find their display names and add them to the objects
        if ($gposAffectingWSUS) {
            Write-Host -Object "[Info] Found GPOs that affect WSUS settings."
            $gposAffectingWSUS = $gposAffectingWSUS | ForEach-Object {
                $gpoId = $_.Id
                $gpoDisplayName = if ($gpoId -eq "Local Group Policy") {
                    "Local Group Policy"
                } else {
                    $activeGPOs | Where-Object { $_.GPOName -eq $gpoId } | Select-Object -ExpandProperty DisplayName
                }

                [PSCustomObject]@{
                    "WSUS Settings Source" = "GPO"
                    "WSUS Status"          = $_.GPOStatus
                    "GPO Display Name"     = $gpoDisplayName
                    "Update Server"        = $_.UpdateServer
                    "Statistics Server"    = $_.StatisticsServer
                }
            }

            # Find the active WSUS settings based on the registry and GPOs
            $ActiveWSUSSettings = $gposAffectingWSUS | Where-Object { $_."WSUS Status" -eq $WSUSStatus }
            
            # If the registry settings are configured, filter the active settings to only include those that match the registry settings
            if ($wsusServerFromRegistry -ne "Not Configured") {
                $ActiveWSUSSettings = $ActiveWSUSSettings | Where-Object { $_."Update Server" -eq $wsusServerFromRegistry }
            }

            if ($statisticsServerFromRegistry -ne "Not Configured") {
                $ActiveWSUSSettings = $ActiveWSUSSettings | Where-Object { $_."Update Server" -eq $statisticsServerFromRegistry }
            }
        } else {
            Write-Host -Object "[Info] No GPOs that affect WSUS settings were found."
        }

        # Validate the WSUS servers in the GPOs against the registry settings
        $gposAffectingWSUS | ForEach-Object {
            $UpdateServer = $_."Update Server"
            $StatisticsServer = $_."Statistics Server"

            # If both servers are empty, skip the validation
            if ([string]::IsNullOrWhiteSpace($UpdateServer) -and [string]::IsNullOrWhiteSpace($StatisticsServer)) {
                return
            }

            $displayName = $_."GPO Display Name"

            if (-not [string]::IsNullOrWhiteSpace($UpdateServer) -and $UpdateServer -ne $wsusServerFromRegistry) {
                Write-Host -Object "[Warning] The WSUS update server in the GPO '$DisplayName' ($UpdateServer) does not match the server in the registry ($wsusServerFromRegistry)."
            }
            
            if (-not [string]::IsNullOrWhiteSpace($StatisticsServer) -and $StatisticsServer -ne $statisticsServerFromRegistry) {
                Write-Host -Object "[Warning] The WSUS statistics server in the GPO '$DisplayName' ($StatisticsServer) does not match the server in the registry ($statisticsServerFromRegistry)."
            }
        }
    }

    # Output all GPOs to the host if there are more than one
    if ($gposAffectingWSUS.Count -gt 1) {
        Write-Host "`n### All GPOs affecting WSUS settings: ###`n"
        ($gposAffectingWSUS | Format-List | Out-String).Trim() | Out-Host
    }

    # Write output object to the activity feed
    if (-not [string]::IsNullOrWhiteSpace($ActiveWSUSSettings)) {
        Write-Host "`n### Active WSUS settings: ###`n"
        ($ActiveWSUSSettings | Format-List | Out-String).Trim() | Out-Host
    }

    # If WSUS settings are active, capture the currently applied GPOs for attribution/troubleshooting
    $appliedGPOs = $null
    if (-not [string]::IsNullOrWhiteSpace($ActiveWSUSSettings)) {
        $allAppliedGPOs = Get-AppliedGPOs

        if ($allAppliedGPOs) {
            Write-Host -Object "`n[Info] Currently applied Group Policy Objects: $($allAppliedGPOs -join ', ')"

            # Narrow down to GPOs whose name suggests they affect WSUS/Windows Update/patching, since the full applied-GPO list can easily exceed a custom field's character limit
            $appliedGPOs = $allAppliedGPOs | Where-Object { $_ -match "WSUS|Update|Patch" }

            if ($appliedGPOs) {
                Write-Host -Object "[Info] Of those, the following appear related to WSUS/Windows Update by name: $($appliedGPOs -join ', ')"
            } else {
                Write-Host -Object "[Info] None of the currently applied GPOs appear related to WSUS/Windows Update by name."
            }
        } else {
            Write-Host -Object "`n[Warning] Unable to determine the currently applied Group Policy Objects."
        }
    }

    # If requested, test connectivity to Microsoft's Windows Update endpoints. Independent of the registry/GPO state above, since it's checking whether the network path to
    # Microsoft is even open - relevant both before and after -RemoveWSUSSettings, since an environment that only ever firewalled traffic to the internal WSUS server will
    # still fail to reach Microsoft even with a perfectly clean registry
    $connectivityResults = $null
    if ($TestWindowsUpdateConnectivity) {
        Write-Host -Object "`n[Info] Testing connectivity to Windows Update endpoints..."
        $connectivityResults = Test-WindowsUpdateConnectivity

        foreach ($result in $connectivityResults) {
            if ($result.TCPConnected) {
                Write-Host -Object "[Info] Reachable: $($result.Hostname):$($result.Port)"
            } elseif (-not $result.DNSResolved) {
                Write-Host -Object "[Warning] DNS resolution failed for $($result.Hostname). This can indicate a DNS server or proxy configuration issue."
            } else {
                Write-Host -Object "[Warning] Unable to reach $($result.Hostname) on port $($result.Port). This can indicate a firewall or proxy blocking Windows Update traffic."
            }
        }

        # Wrapped in @() so Where-Object returning zero or one match still yields a real array - otherwise a zero-match result is $null and $null.Count silently renders as blank instead of 0
        $unreachableEndpoints = @($connectivityResults | Where-Object { -not $_.TCPConnected })
        $reachableCount = @($connectivityResults | Where-Object { $_.TCPConnected }).Count
        $totalEndpointCount = @($connectivityResults).Count

        if ($unreachableEndpoints) {
            Write-Host -Object "[Warning] $($unreachableEndpoints.Count) of $totalEndpointCount Windows Update endpoints could not be reached. If this device previously relied on WSUS exclusively, outbound firewall/proxy rules may need to be updated to allow direct access to Microsoft's update servers."
        } else {
            Write-Host -Object "[Info] All $totalEndpointCount tested Windows Update endpoints are reachable."
        }
    }

    # Inspect the FULL contents of the Windows Update policy key, not just the WSUS server trio checked above. Several other policy values in
    # this same key can independently cause 0x80240438 ("no route or network connectivity to the endpoint") even after every WSUS server value
    # is gone, so a "WSUS is Not Configured" result can still hide the value that's actually stopping the scan. Runs before any removal below so
    # it reports what was present at scan time.
    Write-Host -Object "`n[Info] Inspecting all Windows Update policy values for scan-blocking settings..."
    $policyDiagnostics = Get-WindowsUpdatePolicyDiagnostics -Path $wsusRegPath
    $blockingPolicyValues = @($policyDiagnostics | Where-Object { $_.IsBlocker })

    if (-not $policyDiagnostics) {
        Write-Host -Object "[Info] No Windows Update policy values are present (the '$wsusRegPath' key is absent or empty)."
    } else {
        if ($blockingPolicyValues) {
            Write-Host -Object "[Warning] Found $($blockingPolicyValues.Count) Windows Update policy value(s) that can block or redirect the update scan:"
            foreach ($finding in $blockingPolicyValues) {
                Write-Host -Object "[Warning]   $($finding.Name) = $($finding.Value)  ->  $($finding.Explanation)"
            }
            Write-Host -Object "[Warning] These are set independently of the WSUS server address, so a clean WSUS audit won't show them. Because Group Policy can't reach a domain controller to refresh, a tattooed value like this stays frozen in the registry; use -RemoveWSUSSettings to clear the whole key, and confirm the source GPO (domain or Local) is disabled so it isn't rewritten on the next policy refresh."
        } else {
            Write-Host -Object "[Info] No known scan-blocking policy values were found in the Windows Update policy key."
        }

        # Show every value present for context, since a non-standard value not in the known-blocker list can still be worth eyeballing
        Write-Host -Object "[Info] All values currently present under the Windows Update policy key:"
        foreach ($finding in $policyDiagnostics) {
            Write-Host -Object "[Info]   $($finding.Key.Replace('HKLM:\',''))\$($finding.Name) = $($finding.Value)"
        }
    }

    # Inspect which update service the agent is actually bound to. This is datastore state, not policy, so a WSUS service still registered here
    # is a direct cause of 0x80240438 that a clean policy key won't reveal - and the most likely remaining culprit once the registry/GPO side is
    # confirmed clean. Runs before any cache reset below so it reports the binding as it stands at scan time.
    Write-Host -Object "`n[Info] Checking which update service the Windows Update Agent is bound to..."
    $registeredServices = Get-RegisteredUpdateServices
    $boundNonMicrosoftServices = @($registeredServices | Where-Object { $_.IsConcern })

    if (-not $registeredServices) {
        Write-Host -Object "[Warning] Could not enumerate the registered update services."
    } else {
        foreach ($service in $registeredServices) {
            $label = if ($service.KnownName) { $service.KnownName } else { "Unknown/third-party" }
            $flags = @()
            if ($service.IsDefaultAUService) { $flags += "DefaultAUService" }
            if ($service.IsRegisteredWithAU) { $flags += "RegisteredWithAU" }
            $flagText = if ($flags) { " [$($flags -join ', ')]" } else { "" }

            Write-Host -Object "[Info]   $($service.Name) ($label)$flagText"
            if ($service.ServiceUrl) { Write-Host -Object "[Info]       Service URL: $($service.ServiceUrl)" }
        }

        if ($boundNonMicrosoftServices) {
            Write-Host -Object "[Warning] The Windows Update Agent is still bound to a WSUS/third-party update service, so WSUS is EFFECTIVELY still active on this device even if the policy registry reads 'Not Configured' - this binding, not the policy key, is what a scan actually uses:"
            foreach ($service in $boundNonMicrosoftServices) {
                Write-Host -Object "[Warning]   $($service.Name) - Service URL: $(if ($service.ServiceUrl) { $service.ServiceUrl } else { 'n/a (endpoint recorded in the agent datastore / WindowsUpdate.log)' })"
            }
            Write-Host -Object "[Warning] A managed WSUS binding does NOT clear by removing the registry settings or resetting the cache. It clears only when the device completes a Group Policy cycle against a reachable domain controller (on-site or VPN) with no WSUS configured, or when the device is removed from the domain."
        } else {
            Write-Host -Object "[Info] The agent is bound only to Microsoft's update service(s); no stale WSUS/third-party service registration was found."
        }
    }

    # If requested, remove the WSUS settings from the registry. This runs before the custom field is written, since the field should reflect the end result of this run, not the pre-removal snapshot already shown above
    if ($RemoveWSUSSettings) {
        Write-Host -Object "`n[Info] Removing WSUS settings from the registry..."
        Remove-WSUSRegistrySettings -Path $wsusRegPath
    }

    # If requested, unregister any stale WSUS/third-party service still bound to the agent (surfaced by the service-binding check above). This is
    # the fix for a WSUS service that remains the DefaultAUService after the registry/GPO are clean - which -ResetWindowsUpdateCache does NOT clear,
    # since the binding lives outside SoftwareDistribution. Runs before the cache reset so the datastore is intact for the COM removal, then the
    # reset (if also requested) rebuilds cleanly on top of the corrected service list.
    # The outcome is judged by the post-remediation re-audit below (whether the binding is actually gone), not by this call's return -
    # a managed binding can't be removed locally, so its return isn't a reliable success signal. Discard it to avoid a dead variable.
    if ($UnregisterStaleUpdateServices) {
        if ($boundNonMicrosoftServices) {
            Write-Host -Object "`n[Info] Unregistering stale WSUS/third-party update service(s) from the Windows Update Agent..."
            $null = Remove-StaleUpdateServiceRegistration -Services $boundNonMicrosoftServices
        } else {
            Write-Host -Object "`n[Info] No stale WSUS/third-party update service was bound to the agent; nothing to unregister."
        }
    }

    # If requested, reset the Windows Update cache so the agent rebuilds it from scratch instead of continuing to reference anything tied to the old WSUS server
    $cacheResetSucceeded = $null
    if ($ResetWindowsUpdateCache) {
        Write-Host -Object "`n[Info] Resetting the Windows Update cache..."
        $cacheResetSucceeded = Reset-WindowsUpdateCache
    }

    # Re-audit the bound update services so the console + custom field reflect the post-remediation state (i.e. whether the WSUS binding is actually gone)
    $finalBoundNonMicrosoftServices = $boundNonMicrosoftServices
    if ($UnregisterStaleUpdateServices -and $boundNonMicrosoftServices) {
        $finalRegisteredServices = Get-RegisteredUpdateServices
        $finalBoundNonMicrosoftServices = @($finalRegisteredServices | Where-Object { $_.IsConcern })

        if ($finalBoundNonMicrosoftServices) {
            Write-Host -Object "[Warning] A WSUS/third-party update service is STILL bound after the unregister attempt: $(($finalBoundNonMicrosoftServices | ForEach-Object { $_.Name }) -join ', '). This is a managed registration; it cannot be removed locally while the device is domain-joined. It will clear when the device next completes a Group Policy cycle against a reachable domain controller, or when the device is removed from the domain."
        } else {
            Write-Host -Object "[Info] Confirmed: no WSUS/third-party update service remains bound to the agent. The agent will scan against Microsoft's update service."
        }
    }

    # Re-check the live registry for the final WSUS state. If nothing was removed above, this simply confirms what was already detected; if removal ran, this reflects whether it actually took
    $finalWSUSStatus = "Not Configured"
    $finalUpdateServer = "Not Configured"
    $finalStatisticsServer = "Not Configured"

    if (Test-Path -Path $wsusRegPath) {
        $finalUseWUServer = (Get-ItemProperty -Path "$wsusRegPath\AU" -ErrorAction SilentlyContinue).UseWUServer
        switch ($finalUseWUServer) {
            0 { $finalWSUSStatus = "Disabled" }
            1 { $finalWSUSStatus = "Enabled" }
        }

        $finalServerReg = Get-ItemProperty -Path $wsusRegPath -Name WUServer, WUStatusServer -ErrorAction SilentlyContinue
        if ($finalServerReg.WUServer) { $finalUpdateServer = $finalServerReg.WUServer }
        if ($finalServerReg.WUStatusServer) { $finalStatisticsServer = $finalServerReg.WUStatusServer }
    }

    # Determine the EFFECTIVE WSUS state for reporting. The policy registry can read "Not Configured" while the Windows Update Agent is
    # STILL bound to a WSUS service - a managed registration lives in the agent's datastore, not the policy key. When that's the case WSUS
    # is effectively still active (the binding, not the empty policy key, is what a scan uses), so the report must lead with the binding.
    # This fixes the custom field previously reading "WSUS Status: Not Configured" on a device where a WSUS service was clearly still bound.
    if ($finalBoundNonMicrosoftServices) {
        $effectiveWSUSState = "Bound to service ($(($finalBoundNonMicrosoftServices | ForEach-Object { $_.Name }) -join ', '))"
    } elseif ($finalWSUSStatus -ne "Not Configured") {
        $effectiveWSUSState = "$finalWSUSStatus (policy)"
    } else {
        $effectiveWSUSState = "Not Configured"
    }

    # If a custom field was specified, write to it
    if ($CustomFieldName) {
        # Initiate the custom field value
        $customFieldValue = [System.Text.StringBuilder]::new()

        # Fields are appended in priority order - the most actionable/diagnostic items first, the verbose applied-GPO list last - because the
        # final value is truncated to fit NinjaOne's 200-character text-field limit below, and truncation drops from the end. The full detail
        # for every field is always in the console output above regardless of what the field can hold.

        # 1) EFFECTIVE WSUS state - reflects a bound managed service, not just the policy key (see $effectiveWSUSState above). This is the
        # fix for the field previously reading "Not Configured" while a WSUS service was clearly still bound. The bound-service name is
        # folded into this headline, so there's no separate (and previously contradictory) "Bound Non-MS Service" field anymore.
        [void]$customFieldValue.Append("WSUS: $effectiveWSUSState")

        # Include the policy server address(es) only when a WSUS server is actually set in policy
        if ($finalWSUSStatus -ne "Not Configured") {
            if ($finalUpdateServer -eq $finalStatisticsServer) {
                [void]$customFieldValue.Append(" | Update and Statistics Server: $finalUpdateServer")
            } else {
                [void]$customFieldValue.Append(" | Update Server: $finalUpdateServer | Statistics Server: $finalStatisticsServer")
            }
        }

        # 2) Scan-blocking policy values (names only) - a direct cause of a failed scan, so it ranks high
        if ($blockingPolicyValues) {
            [void]$customFieldValue.Append(" | Scan Blockers: $($blockingPolicyValues.Name -join ', ')")
        }

        # 3) Result of the unregister action, if it was requested. Judge it by whether the binding is actually gone now - NOT by the COM
        # call's return - since a managed binding can't be removed locally; report that it needs a DC/domain change rather than "Failed".
        if ($UnregisterStaleUpdateServices -and $boundNonMicrosoftServices) {
            [void]$customFieldValue.Append(" | Unregister: $(if (-not $finalBoundNonMicrosoftServices) { 'Cleared' } else { 'Blocked-NeedsDC/Domain' })")
        }

        # 4) DC reachability context (domain-joined only) - explains whether a managed WSUS binding can be expected to clear on this run
        if ($null -ne $DomainControllerReachable) {
            [void]$customFieldValue.Append(" | DC: $(if ($DomainControllerReachable) { 'Reachable' } else { 'Unreachable' })")
        }

        # 5) Cache reset result, if it was requested
        if ($null -ne $cacheResetSucceeded) {
            [void]$customFieldValue.Append(" | Cache Reset: $(if ($cacheResetSucceeded) { 'Completed' } else { 'Failed' })")
        }

        # 6) Windows Update endpoint connectivity count (full per-endpoint breakdown is in the console output)
        if ($connectivityResults) {
            [void]$customFieldValue.Append(" | WU Connectivity: $reachableCount/$totalEndpointCount reachable")
        }

        # 7) GPO attributed as the source, if any
        if ($ActiveWSUSSettings."WSUS Settings Source" -eq "GPO") {
            $gpoName = $ActiveWSUSSettings."GPO Display Name"
            [void]$customFieldValue.Append(" | GPO Name: $gpoName")
        }

        # 8) Applied GPO names (longest, least actionable - deliberately last so it's the first thing dropped by truncation)
        if ($appliedGPOs) {
            [void]$customFieldValue.Append(" | Applied GPOs: $($appliedGPOs -join ', ')")
        }

        # Set the custom field
        try {
            $customFieldValue = $customFieldValue.ToString()

            # NinjaOne single-line text custom fields reject values of 200 characters or more, which fails the whole action. Truncate defensively
            # (with an ellipsis so it's obvious the value was clipped) so a long applied-GPO list can never turn a successful run into a failed one.
            $maxCustomFieldLength = 199
            if ($customFieldValue.Length -gt $maxCustomFieldLength) {
                $customFieldValue = $customFieldValue.Substring(0, $maxCustomFieldLength - 3).TrimEnd() + "..."
            }

            Write-Host -Object "`n[Info] Setting the custom field '$CustomFieldName' with the value:`n$customFieldValue"
            Set-CustomField -Name $CustomFieldName -Value $customFieldValue -Type "Text" -ErrorAction Stop
            Write-Host -Object "[Info] Successfully set the custom field '$CustomFieldName'."
        } catch {
            Write-Host -Object "[Error] Error setting the custom field '$CustomFieldName'"
            Write-Host -Object "[Error] $($_.Exception.Message)"
            $ExitCode = 1
        }
    }

    exit $ExitCode
}
end {
    
    
    
}