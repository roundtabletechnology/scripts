#Requires -Version 5.1

<#
.SYNOPSIS
    Runs gpresult against the local machine and reports which Group Policy Objects are applied, which domain controller served the policy, and (best-effort) the individual settings those GPOs are pushing.
.DESCRIPTION
    Runs gpresult against the local machine and reports which Group Policy Objects are applied, which domain controller served the policy, and (best-effort) the individual settings those GPOs are pushing.

    This is a read-only diagnostic, not a fix - it exists for exactly the kind of question that came up while chasing a stale WSUS setting that kept reappearing after removal: "which GPO is actually winning here, and did it come from a domain controller we don't expect?" (e.g. a leftover DC from an acquired/merged domain).

    Two data sources are combined:
    - `gpresult /r` (plain text) for the reliable summary: which domain controller served this policy application ("Group Policy was applied from"), the domain name/type, and the list of applied vs. filtered-out GPOs. This format is simple and has been stable for years.
    - `gpresult /h` (HTML report) for a best-effort read-out of the actual resolved settings (policy/value/winning GPO), since the plain-text output doesn't include per-setting detail at all. Microsoft doesn't publish the HTML report's internal structure and it isn't guaranteed to be identical across every Windows version, so this script parses it generically - by whatever column headers actually appear in each table - rather than assuming fixed field names. If nothing gets parsed (or the table layout doesn't match what's expected), the raw HTML file is still saved to disk and its path is printed so it can be opened directly in a browser.

    IMPORTANT nuance on "where the GPO originated": a GPO's SYSVOL contents replicate to every domain controller in its domain, so there is no single "home" DC for a given GPO once it's created. What this script CAN tell you concretely is (a) which DC served this specific policy application just now, and (b) which domain each applied GPO belongs to, if that detail is present in the HTML report. Run this across a few machines (or a few times on the same machine) to see whether "applied from" bounces between different domain controllers - that's the practical way to confirm more than one DC is in play.

.PARAMETER CustomFieldName
    The name of the (Text) custom field to set with a compact summary of the results.

.PARAMETER IncludeUserSettings
    If specified, also captures and reports the User Configuration side of RSOP data, not just Computer Configuration. When this script runs as SYSTEM (the normal case under NinjaRMM), the "user" RSOP reflects the SYSTEM account, not whichever human is logged in interactively - so this is most useful when run interactively as the user in question.

.PARAMETER SettingFilter
    An optional keyword (e.g. "Update", "WSUS") to narrow the best-effort settings read-out to rows that mention it. Without this, every settings row that was successfully parsed from the HTML report is shown.

.PARAMETER ForceGPUpdate
    If specified, runs `gpupdate /force` before capturing gpresult, so the report reflects the current live policy state rather than whatever was last applied (which could be up to the slow-link/background-refresh interval old).

.PARAMETER ReportPath
    Folder to save the raw gpresult HTML report to. Defaults to "$env:ProgramData\GPResultReports". The report is timestamped and left in place after the script runs so it can be pulled and opened directly in a browser if the parsed read-out below is incomplete.

.EXAMPLE
    (No Parameters)

    [Info] Script Version: 1.1
    [Info] Checking elevation...

    ### Computer Settings (RSOP) ###

    Last Group Policy Application : 7/14/2026 7:37:44 AM
    Applied From (Domain Controller): DC02.contoso.local
    Domain Name                    : CONTOSO
    Domain Type                    : Windows2008orLater

    Applied Group Policy Objects:
        - Default Domain Policy
        - Small Business Server Update Services Common Settings Policy
        - Local Group Policy

    Filtered / Not Applied GPOs:
        - Old Disabled Policy (Filtering: Disabled)

    [Info] Generating the gpresult HTML report for a best-effort settings read-out...
    [Info] Saved raw gpresult HTML report to: C:\ProgramData\GPResultReports\GPResult_RTT-DL1AU9R_20260714120000.html
    [Info] Parsed 42 setting rows from the HTML report.

    ### Settings (best-effort, parsed from HTML) ###

    Category                  Policy                                  State    Winning GPO
    --------                  ------                                  -----    -----------
    Administrative Templates  Specify intranet Microsoft update service location  Enabled  Small Business Server Update Services Common Settings Policy

.EXAMPLE
    -SettingFilter "Update" -CustomFieldName "GPResultSummary" -ForceGPUpdate

    Forces a policy refresh first, then reports only settings rows mentioning "Update", and publishes a compact summary to the 'GPResultSummary' custom field.

.NOTES
    Minimum OS Architecture Supported: Windows 10, Windows Server 2016
    Version: 1.1
    Release Notes:
    - Rewrote the settings table detection against a real gpresult HTML report (Windows 11 24H2). The v1.0 approach of matching on loose header-text keywords (e.g. "Policy") false-positived on the decorative class="title" banner table, whose single cell literally reads "Group Policy Results" - which contains the substring "Policy". Real resolved-setting tables consistently use class="info3" with a genuine <th> header row; that's what's matched now.
    - Fixed category/heading detection: gpresult's report uses <span class="sectionTitle">Text</span> for section headings, not <h1>-<h4> tags, so v1.0's heading lookup silently matched nothing and every table fell back to the hardcoded "General" default category.
    - Fixed compound settings (e.g. "Configure Automatic Updates") producing a stray, mis-labeled row (observed live: "interval (hours): 1" bleeding into the Windows Update category under the wrong column headers). These settings embed a nested <table class="subtable*"> one level deep inside a single cell, which never nests further; a non-greedy <table>...</table> match against the OUTER settings table was stopping at the NESTED table's closing tag instead of the true outer one, truncating the outer table and leaking the nested table's own rows in. Fixed by stripping every subtable out of the HTML before parsing, since doing so is always safe (they don't nest). This also surfaced that gpresult can re-declare a fresh <th> header row partway through a single class="info3" table right after a compound setting's nested detail - any all-<th> row encountered mid-table now updates the active header set for the rows that follow, instead of being emitted as a stray data row under the stale original header.
    - Added Get-GPResultGPOOrigin, which parses the class="info" metadata table under each Applied/Denied GPO (Link Location, Enforced, Disabled, Revision) - Link Location is the concrete, checkable answer to "which domain does this GPO belong to". Any GPO whose Link Location doesn't match the computer's own domain is flagged explicitly, since that's the real signal to look for a second/leftover domain or domain controller (e.g. from a merged/acquired company).
    - Fixed Format-Table -AutoSize producing unreadable character-by-character output (e.g. a single "G" or "-" per line) when run under NinjaRMM. With no real attached console, PowerShell can detect an absurdly narrow window width, which poisons -AutoSize's column-fitting math. Piped through Out-String -Width 300 everywhere Format-Table -AutoSize is used, forcing a wide virtual buffer regardless of the actual (or nonexistent) console width.

    Created 7/14/2026 BBJr
#>

[CmdletBinding()]
param (
    [string]$CustomFieldName,
    [switch]$IncludeUserSettings,
    [string]$SettingFilter,
    [switch]$ForceGPUpdate,
    [string]$ReportPath
)
begin {
    $ScriptVersion = "1.1"
    Write-Host -Object "[Info] Script Version: $ScriptVersion"

    # Import NinjaRMM script variables
    if ($env:customFieldName) { $CustomFieldName = $env:customFieldName }
    if ($env:includeUserSettings -eq "true") { $IncludeUserSettings = $true }
    if ($env:settingFilter) { $SettingFilter = $env:settingFilter }
    if ($env:forceGPUpdate -eq "true") { $ForceGPUpdate = $true }
    if ($env:reportPath) { $ReportPath = $env:reportPath }

    if (-not $ReportPath) { $ReportPath = "$env:ProgramData\GPResultReports" }

    # Function to test if the current session is running with Administrator privileges
    function Test-IsElevated {
        [CmdletBinding()]
        param ()

        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]'544')
    }

    # Function to run gpresult /r and pull out the reliable summary fields (RSOP is queried per-scope, so Computer and User sections
    # repeat the same label text - "Domain Name:", "Group Policy was applied from:", etc. - and must be parsed from within their own
    # section slice rather than matched globally, or a User-side value could get mistaken for the Computer-side one)
    function Get-GPResultSummary {
        [CmdletBinding()]
        param (
            [switch]$IncludeUserSettings
        )

        $arguments = @("/r")
        if (-not $IncludeUserSettings) { $arguments += "/scope:computer" }

        try {
            $rawLines = & "$env:SystemRoot\System32\gpresult.exe" @arguments 2>&1
        }
        catch {
            Write-Host -Object "[Error] Failed to run 'gpresult.exe /r'."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            return $null
        }

        # Extract lines belonging to one top-level section (e.g. "COMPUTER SETTINGS") up to (but not including) the next top-level section
        function Get-TopLevelSectionLines {
            param ([string[]]$Lines, [string]$HeaderText)

            for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
                if ($Lines[$i].Trim() -eq $HeaderText -and $Lines[$i + 1] -match "^\s*-+\s*$") {
                    $sectionLines = [System.Collections.Generic.List[string]]::new()
                    for ($j = $i + 2; $j -lt $Lines.Count; $j++) {
                        # Stop at the next top-level section header (an unindented line immediately followed by a dashed underline)
                        if ($Lines[$j] -notmatch "^\s" -and $j + 1 -lt $Lines.Count -and $Lines[$j + 1] -match "^\s*-+\s*$" -and $Lines[$j].Trim() -ne "") {
                            break
                        }
                        $sectionLines.Add($Lines[$j])
                    }
                    return $sectionLines
                }
            }
            return $null
        }

        # Extract the lines under a nested sub-header (e.g. "Applied Group Policy Objects") within an already-sliced section
        function Get-SubSectionLines {
            param ([string[]]$Lines, [string]$HeaderText)

            for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
                if ($Lines[$i].Trim() -eq $HeaderText -and $Lines[$i + 1] -match "^\s*-+\s*$") {
                    $sectionLines = [System.Collections.Generic.List[string]]::new()
                    for ($j = $i + 2; $j -lt $Lines.Count; $j++) {
                        if ([string]::IsNullOrWhiteSpace($Lines[$j])) { break }
                        $sectionLines.Add($Lines[$j].Trim())
                    }
                    return $sectionLines
                }
            }
            return $null
        }

        function ConvertTo-Summary {
            param ([string[]]$SectionLines, [string]$ScopeName)

            if (-not $SectionLines) { return $null }

            $summary = [PSCustomObject]@{
                Scope             = $ScopeName
                LastApplied       = $null
                AppliedFrom       = $null
                DomainName        = $null
                DomainType        = $null
                AppliedGPOs       = @()
                FilteredGPOs      = @()
            }

            foreach ($line in $SectionLines) {
                if ($line -match "^\s*Last time Group Policy was applied:\s*(.+)$") { $summary.LastApplied = $Matches[1].Trim() }
                elseif ($line -match "^\s*Group Policy was applied from:\s*(.+)$") { $summary.AppliedFrom = $Matches[1].Trim() }
                elseif ($line -match "^\s*Domain Name:\s*(.+)$") { $summary.DomainName = $Matches[1].Trim() }
                elseif ($line -match "^\s*Domain Type:\s*(.+)$") { $summary.DomainType = $Matches[1].Trim() }
            }

            $appliedGPOLines = Get-SubSectionLines -Lines $SectionLines -HeaderText "Applied Group Policy Objects"
            if ($appliedGPOLines) {
                $summary.AppliedGPOs = @($appliedGPOLines | Where-Object { $_ -and $_ -ne "N/A" })
            }

            $filteredLines = Get-SubSectionLines -Lines $SectionLines -HeaderText "The following GPOs were not applied because they were filtered out"
            if ($filteredLines) {
                $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()
                for ($i = 0; $i -lt $filteredLines.Count; $i++) {
                    if ($filteredLines[$i] -match "^Filtering:") { continue }
                    $reason = if ($i + 1 -lt $filteredLines.Count -and $filteredLines[$i + 1] -match "^Filtering:\s*(.+)$") { $Matches[1].Trim() } else { "Unknown" }
                    $filtered.Add([PSCustomObject]@{ Name = $filteredLines[$i]; Reason = $reason })
                }
                $summary.FilteredGPOs = $filtered
            }

            return $summary
        }

        $computerLines = Get-TopLevelSectionLines -Lines $rawLines -HeaderText "COMPUTER SETTINGS"
        $userLines = if ($IncludeUserSettings) { Get-TopLevelSectionLines -Lines $rawLines -HeaderText "USER SETTINGS" } else { $null }

        [PSCustomObject]@{
            Computer = ConvertTo-Summary -SectionLines $computerLines -ScopeName "Computer"
            User     = if ($userLines) { ConvertTo-Summary -SectionLines $userLines -ScopeName "User" } else { $null }
        }
    }

    # Function to generate the gpresult HTML report and do a best-effort, generic parse of its settings tables.
    # Deliberately does not hardcode gpresult's HTML CSS classes/element IDs, since Microsoft doesn't document them and they
    # aren't guaranteed identical across Windows versions - instead, any <table> whose header row contains a recognizable
    # column name is treated as a settings table, and each row is returned keyed by whatever that header text actually is
    function Get-GPResultSettingsReport {
        [CmdletBinding()]
        param (
            [switch]$IncludeUserSettings,
            [Parameter(Mandatory = $true)]
            [string]$OutputPath
        )

        $arguments = @("/h", $OutputPath, "/f")
        if (-not $IncludeUserSettings) { $arguments += "/scope:computer" }

        try {
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $OutputPath -Parent) -Force -ErrorAction Stop
            $gpresultHtmlOutput = & "$env:SystemRoot\System32\gpresult.exe" @arguments 2>&1
        }
        catch {
            Write-Host -Object "[Error] Failed to generate the gpresult HTML report."
            Write-Host -Object "[Error] $($_.Exception.Message)"
            return [PSCustomObject]@{ ReportPath = $null; Rows = @() }
        }

        if (-not (Test-Path -Path $OutputPath)) {
            Write-Host -Object "[Error] gpresult did not produce an HTML report at '$OutputPath'."
            if ($gpresultHtmlOutput) { $gpresultHtmlOutput | ForEach-Object { Write-Host -Object "[Error] $_" } }
            return [PSCustomObject]@{ ReportPath = $null; Rows = @() }
        }

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

        try {
            $html = Get-Content -Path $OutputPath -Raw -ErrorAction Stop

            # Compound settings (e.g. "Configure Automatic Updates") embed a nested <table class="subtable*"> one level deep,
            # entirely within a single <td> of one row, and these subtables never nest further. Left in place, a non-greedy
            # <table>...</table> match against the OUTER settings table would stop at the NESTED table's closing tag instead
            # of the true outer one - truncating the outer table's captured content and leaking the nested table's own rows
            # in as if they belonged to the outer table (observed live: a stray "interval (hours): 1" row bleeding into the
            # Windows Update settings under the wrong column headers). Stripping every subtable out first - safe since they
            # never nest - fixes both problems in one pass; the row that contained one just becomes an empty, skippable cell
            $subtablePattern = '<table\b[^>]*class="subtable[^"]*"[^>]*>(?:(?!<table\b)(?!</table>).)*?</table>'
            $html = [regex]::Replace($html, $subtablePattern, "", [System.Text.RegularExpressions.RegexOptions]::Singleline)

            $headerCellPattern = "<th[^>]*>(.*?)</th>"
            $dataCellPattern = "<t[hd][^>]*>(.*?)</t[hd]>"

            # gpresult's HTML report renders a real, resolved-settings table with class="info3" and a genuine <th> header row
            # (confirmed against a live report: Component Status, Account Policies, Administrative Templates settings, WMI Filters
            # all use "info3"). Plain class="info" tables are 2-column label/value metadata with no header row at all (General
            # computer info, and each individual GPO's Link Location/Enforced/Revision block) and are handled separately below.
            # An earlier version of this matched on loose header-text keywords like "Policy", which false-positived on the
            # decorative class="title" banner table (its one cell literally reads "Group Policy Results", which contains "Policy")
            $settingsTablePattern = '<table[^>]*class="info3"[^>]*>(.*?)</table>'

            # Different setting categories (Administrative Templates vs. Security Settings, etc.) use different column layouts,
            # so each table is tagged with the nearest preceding section heading - this lets rows later be grouped and displayed
            # per-category, instead of one flat Format-Table that would silently drop columns not present on the first row.
            # gpresult renders section headings as <span class="sectionTitle">Text</span>, not <h1>-<h4> tags
            $headingMatches = [regex]::Matches($html, '<span class="sectionTitle"[^>]*>(.*?)</span>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $headings = foreach ($headingMatch in $headingMatches) {
                [PSCustomObject]@{
                    Index = $headingMatch.Index
                    Text  = [System.Net.WebUtility]::HtmlDecode(($headingMatch.Groups[1].Value -replace "<[^>]+>", "")).Trim()
                }
            }

            $tableMatches = [regex]::Matches($html, $settingsTablePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

            foreach ($tableMatch in $tableMatches) {
                $rowMatches = [regex]::Matches($tableMatch.Groups[1].Value, "<tr[^>]*>(.*?)</tr>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
                if ($rowMatches.Count -lt 2) { continue }

                $headerCells = [regex]::Matches($rowMatches[0].Groups[1].Value, $headerCellPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline) |
                    ForEach-Object { [System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace "<[^>]+>", "")).Trim() }

                # A real header row must actually use <th> cells - a table that starts straight into <td> data (no <th> at all)
                # isn't a genuine settings table under this report's markup, even if it happens to have class="info3"
                if (-not $headerCells) { continue }

                $category = ($headings | Where-Object { $_.Index -lt $tableMatch.Index } | Select-Object -Last 1).Text
                if (-not $category) { $category = "General" }

                for ($i = 1; $i -lt $rowMatches.Count; $i++) {
                    # Rows that contain a nested <table> (e.g. class="subtable_frame") hold multi-value sub-settings one level
                    # deeper than this basic read-out parses - skip them here rather than mis-splitting their nested cells;
                    # they're still fully visible in the raw HTML report saved to disk
                    if ($rowMatches[$i].Groups[1].Value -match "<table") { continue }

                    # A single class="info3" table can re-declare its header partway through (observed for compound settings
                    # like "Configure Automatic Updates", which nests a sub-table then starts a fresh Policy/Setting/Winning GPO
                    # header for the next entry) - detect an all-<th> row and treat it as updating the header for what follows,
                    # rather than emitting it as a data row under the original (now stale) column names
                    $rowHeaderCells = [regex]::Matches($rowMatches[$i].Groups[1].Value, $headerCellPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline) |
                        ForEach-Object { [System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace "<[^>]+>", "")).Trim() }
                    if ($rowHeaderCells) {
                        $headerCells = $rowHeaderCells
                        continue
                    }

                    $dataCells = [regex]::Matches($rowMatches[$i].Groups[1].Value, $dataCellPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline) |
                        ForEach-Object { [System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace "<[^>]+>", "")).Trim() }

                    if (-not $dataCells -or (($dataCells | Where-Object { $_ }).Count -eq 0)) { continue }

                    $rowObject = [ordered]@{ Category = $category }
                    for ($c = 0; $c -lt $headerCells.Count; $c++) {
                        $columnName = if ($headerCells[$c]) { $headerCells[$c] } else { "Column$c" }
                        $rowObject[$columnName] = if ($c -lt $dataCells.Count) { $dataCells[$c] } else { "" }
                    }
                    $rows.Add([PSCustomObject]$rowObject)
                }
            }
        }
        catch {
            Write-Host -Object "[Warning] Failed to parse the gpresult HTML report; the raw file is still available at '$OutputPath'."
            Write-Host -Object "[Warning] $($_.Exception.Message)"
        }

        [PSCustomObject]@{ ReportPath = $OutputPath; Rows = $rows }
    }

    # Function to parse the "Link Location" (and other metadata) for each Applied and Denied GPO, from the class="info" table
    # that follows each GPO's own heading under "Group Policy Objects" in the HTML report. Link Location is the concrete,
    # checkable answer to "which domain did this GPO come from" - a GPO's SYSVOL content replicates to every domain controller
    # in its domain, so this identifies the owning domain, not a single "origin" DC (there isn't one once a GPO is created)
    function Get-GPResultGPOOrigin {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Html
        )

        $sectionHeadingMatches = [regex]::Matches($Html, '<span class="sectionTitle"[^>]*>(Applied GPOs|Denied GPOs)</span>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $sectionHeadings = foreach ($headingMatch in $sectionHeadingMatches) {
            [PSCustomObject]@{ Index = $headingMatch.Index; Text = $headingMatch.Groups[1].Value }
        }

        # Matches a GPO's own heading, e.g. `Small Business Server Update Services Common Settings Policy [{GUID}]` or
        # `Local Group Policy [LocalGPO]`, followed (non-greedily, so it stops at the very next table) by its metadata table
        $gpoMatches = [regex]::Matches($Html, '<span class="sectionTitle"[^>]*>([^<\[]+?)\s*\[([^\]]+)\]</span>.*?<table class="info"\s*>(.*?)</table>', [System.Text.RegularExpressions.RegexOptions]::Singleline)

        foreach ($gpoMatch in $gpoMatches) {
            # Only keep matches that actually fall under "Applied GPOs" or "Denied GPOs" - this pattern could otherwise also
            # match unrelated named sections elsewhere in the report that happen to follow the same "Name [Id]" heading shape
            $status = ($sectionHeadings | Where-Object { $_.Index -lt $gpoMatch.Index } | Select-Object -Last 1).Text
            if (-not $status) { continue }

            $metadataRows = [regex]::Matches($gpoMatch.Groups[3].Value, "<tr><td><strong>(.*?)</strong></td><td>(.*?)</td></tr>")
            $metadata = @{}
            foreach ($metadataRow in $metadataRows) {
                $label = [System.Net.WebUtility]::HtmlDecode($metadataRow.Groups[1].Value).Trim()
                # &nbsp; decodes to U+00A0 (non-breaking space), not a regular space - strip it explicitly so blank metadata
                # values (e.g. an unfiltered GPO's "WMI Filter" cell) come through as an empty string rather than a stray character
                $value = ([System.Net.WebUtility]::HtmlDecode($metadataRow.Groups[2].Value) -replace "<[^>]+>", "") -replace [char]0x00A0, ""
                $metadata[$label] = $value.Trim()
            }

            [PSCustomObject]@{
                Status       = $status
                Name         = [System.Net.WebUtility]::HtmlDecode($gpoMatch.Groups[1].Value).Trim()
                LinkLocation = $metadata["Link Location"]
                Enforced     = $metadata["Enforced"]
                Disabled     = $metadata["Disabled"]
                Revision     = $metadata["Revision"]
            }
        }
    }
}
process {
    try {
        $IsElevated = Test-IsElevated -ErrorAction Stop
    } catch {
        Write-Host -Object "[Error] $($_.Exception.Message)"
        Write-Host -Object "[Error] Unable to determine if the account '$env:Username' is running with Administrator privileges."
        exit 1
    }

    if (!$IsElevated) {
        Write-Host -Object "[Error] Access Denied: Please run with Administrator privileges."
        exit 1
    }

    $ExitCode = 0

    if ($ForceGPUpdate) {
        Write-Host -Object "[Info] Forcing a Group Policy update before capturing results..."
        try {
            $gpupdateProcess = Start-Process -FilePath "$env:SystemRoot\System32\gpupdate.exe" -ArgumentList "/force" -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($gpupdateProcess.ExitCode -ne 0) {
                Write-Host -Object "[Warning] gpupdate exited with code $($gpupdateProcess.ExitCode). Results below may not reflect the very latest policy state."
            } else {
                Write-Host -Object "[Info] Group policy update completed successfully."
            }
        } catch {
            Write-Host -Object "[Warning] Failed to run gpupdate.exe: $($_.Exception.Message)"
        }
    }

    # Reliable summary from gpresult /r
    Write-Host -Object "`n[Info] Retrieving RSOP summary (gpresult /r)..."
    $summary = Get-GPResultSummary -IncludeUserSettings:$IncludeUserSettings

    function Write-ScopeSummary {
        param ([PSCustomObject]$ScopeSummary)

        if (-not $ScopeSummary) { return }

        Write-Host -Object "`n### $($ScopeSummary.Scope) Settings (RSOP) ###`n"
        Write-Host -Object "Last Group Policy Application    : $($ScopeSummary.LastApplied)"
        Write-Host -Object "Applied From (Domain Controller)  : $($ScopeSummary.AppliedFrom)"
        Write-Host -Object "Domain Name                       : $($ScopeSummary.DomainName)"
        Write-Host -Object "Domain Type                       : $($ScopeSummary.DomainType)"

        Write-Host -Object "`nApplied Group Policy Objects:"
        if ($ScopeSummary.AppliedGPOs.Count -gt 0) {
            $ScopeSummary.AppliedGPOs | ForEach-Object { Write-Host -Object "    - $_" }
        } else {
            Write-Host -Object "    (none)"
        }

        if ($ScopeSummary.FilteredGPOs.Count -gt 0) {
            Write-Host -Object "`nFiltered / Not Applied GPOs:"
            $ScopeSummary.FilteredGPOs | ForEach-Object { Write-Host -Object "    - $($_.Name) (Filtering: $($_.Reason))" }
        }
    }

    Write-ScopeSummary -ScopeSummary $summary.Computer
    if ($IncludeUserSettings) {
        Write-Host -Object "`n[Info] Note: since this ran as '$env:Username', the User Settings below reflect that account's RSOP, not necessarily an interactively logged-on user's."
        Write-ScopeSummary -ScopeSummary $summary.User
    }

    # Best-effort settings read-out from gpresult /h
    Write-Host -Object "`n[Info] Generating the gpresult HTML report for a best-effort settings read-out..."
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $htmlOutputPath = Join-Path -Path $ReportPath -ChildPath "GPResult_$($env:COMPUTERNAME)_$timestamp.html"
    $settingsReport = Get-GPResultSettingsReport -IncludeUserSettings:$IncludeUserSettings -OutputPath $htmlOutputPath

    if ($settingsReport.ReportPath) {
        Write-Host -Object "[Info] Saved raw gpresult HTML report to: $($settingsReport.ReportPath)"

        # GPO origin (Link Location) check - the concrete, checkable answer to "which domain does this GPO belong to".
        # Flags any Applied/Denied GPO whose Link Location doesn't match this computer's own domain, since that's the actual
        # signal that a second domain/domain controller (e.g. one left over from a merged/acquired domain) is in play
        try {
            $reportHtml = Get-Content -Path $settingsReport.ReportPath -Raw -ErrorAction Stop
            $gpoOrigins = Get-GPResultGPOOrigin -Html $reportHtml
        } catch {
            Write-Host -Object "[Warning] Failed to parse GPO origin details from the HTML report: $($_.Exception.Message)"
            $gpoOrigins = @()
        }

        if ($gpoOrigins.Count -gt 0) {
            Write-Host -Object "`n### GPO Origin (Link Location) ###"
            ($gpoOrigins | Select-Object Status, Name, LinkLocation, Enforced, Disabled, Revision | Format-Table -AutoSize | Out-String -Width 300).Trim() | Out-Host

            $primaryDomain = $summary.Computer.DomainName
            $foreignGPOs = $gpoOrigins | Where-Object {
                $_.LinkLocation -and $_.LinkLocation -ne "Local" -and $primaryDomain -and $_.LinkLocation -notmatch [regex]::Escape($primaryDomain)
            }
            if ($foreignGPOs) {
                Write-Host -Object "`n[Warning] The following GPOs are linked from a domain that does not match this computer's own domain ('$primaryDomain') - check for a second/leftover domain or domain controller:"
                $foreignGPOs | ForEach-Object { Write-Host -Object "    - $($_.Name): $($_.LinkLocation)" }
            }
        }
    }

    $settingRows = $settingsReport.Rows
    if ($SettingFilter -and $settingRows.Count -gt 0) {
        $settingRows = $settingRows | Where-Object {
            $rowText = ($_.PSObject.Properties.Value -join " ")
            $rowText -match [regex]::Escape($SettingFilter)
        }
    }

    if ($settingsReport.Rows.Count -eq 0) {
        Write-Host -Object "[Warning] No setting rows could be parsed from the HTML report. This can happen if gpresult failed silently, or if this Windows version's report layout doesn't match the generic column-header detection this script uses."
        if ($settingsReport.ReportPath) {
            Write-Host -Object "[Warning] Open the saved report directly to review it manually: $($settingsReport.ReportPath)"
        }
    } else {
        Write-Host -Object "[Info] Parsed $($settingsReport.Rows.Count) setting row(s) from the HTML report$(if ($SettingFilter) { "; $($settingRows.Count) match the filter '$SettingFilter'" })."

        if ($settingRows.Count -gt 0) {
            Write-Host -Object "`n### Settings (best-effort, parsed from HTML) ###"
            # Grouped by category (and Format-Table'd separately per group) since different setting categories use different
            # columns - a single flat Format-Table would only show the columns present on the first row and silently drop the rest
            $settingRows | Group-Object -Property Category | ForEach-Object {
                Write-Host -Object "`n-- $($_.Name) --"
                # -Width forces a wide virtual buffer for Format-Table's column-fitting logic. Without it, running under
                # NinjaRMM (no real attached console) can make PowerShell detect an absurdly narrow window width, causing
                # Format-Table -AutoSize to wrap every column character-by-character into unreadable garbage
                ($_.Group | Select-Object -Property * -ExcludeProperty Category | Format-Table -AutoSize | Out-String -Width 300).Trim() | Out-Host
            }
        } elseif ($SettingFilter) {
            Write-Host -Object "[Info] No parsed rows matched the filter '$SettingFilter'."
        }
    }

    if ($CustomFieldName) {
        $appliedNames = $summary.Computer.AppliedGPOs -join ", "
        $customFieldValue = "Applied From: $($summary.Computer.AppliedFrom) | Domain: $($summary.Computer.DomainName) | GPO Count: $($summary.Computer.AppliedGPOs.Count) | GPOs: $appliedNames"

        if (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue) {
            try {
                Write-Host -Object "`n[Info] Setting the custom field '$CustomFieldName' with the value:`n$customFieldValue"
                Ninja-Property-Set -Name $CustomFieldName -Value $customFieldValue | Out-Null
                Write-Host -Object "[Info] Successfully set the custom field '$CustomFieldName'."
            } catch {
                Write-Host -Object "[Error] Failed to set the custom field '$CustomFieldName'."
                Write-Host -Object "[Error] $($_.Exception.Message)"
                $ExitCode = 1
            }
        } else {
            Write-Host -Object "[Warning] Ninja-Property-Set is not available in this context; skipping custom field update."
        }
    }

    exit $ExitCode
}
end {
}
