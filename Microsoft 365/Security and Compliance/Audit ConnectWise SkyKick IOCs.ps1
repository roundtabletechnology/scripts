<#
.SYNOPSIS
    Read-only audit of one or more Microsoft 365 tenants for the ConnectWise
    Cloud Backup (SkyKick) vendor credential compromise reported by Huntress.

.DESCRIPTION
    Huntress reported (October 2026) that a vendor-held credential for the
    ConnectWise Cloud Backup app (formerly SkyKick) was used to get Microsoft
    Graph tokens in customer tenants from 144.172.64.128. ConnectWise Cloud
    Management service principals were also seen adding themselves to directory
    roles (Exchange Administrator, Global Administrator) and adding client
    secrets to other apps, including MSP management and security tools.
    Source: https://www.huntress.com/blog/vendor-credential-enables-unauthorized-access

    For each tenant this script checks, without changing anything:

      1. ConnectWise / SkyKick enterprise apps: present, and enabled or disabled.
         Matched on the published app IDs and on the vendor's owner tenant ID,
         so unlisted apps from the same vendor are caught too.
      2. Directory roles held by those apps (active and PIM-eligible), plus
         every other service principal holding a privileged directory role.
      3. Secrets and certificates added to ANY app registration or enterprise
         app since -Since (default 2026-10-13). Disabling an app does not remove
         credentials an attacker already added, so this check matters regardless.
      4. Entra audit log: role assignments, credential changes, consents and
         app updates performed BY an app since -Since, with IOC user agents.
      5. Sign-in logs: service principal sign-ins to the ConnectWise apps, and
         any user or app sign-in from the IOC IP addresses.
      6. Conditional Access policies that exclude the ConnectWise apps.
      7. Inventory of every third-party enterprise app (not published by
         Microsoft): publisher, enabled state, application and admin-consented
         delegated permissions, user consents and last sign-in, with high-risk
         permissions and apps unused for 90+ days flagged. This is for spotting
         other apps you may want to remove; it goes to Apps.csv and its own
         section of the HTML report, separate from the IOC findings.

    Every finding includes the portal path and a direct link (opened in the
    right tenant) so you can review, disable or delete it yourself in the UI.
    Results go to the console, a CSV and an HTML report.

    NOTHING IS MODIFIED. Only read scopes are requested.

    Huntress guidance: DISABLE the ConnectWise apps, do not delete them.
    Deleting removes consent and backups need re-consent to resume.

    Licensing and retention:
      - Sign-in logs through Graph need Entra ID P1 or P2. Without it the
        sign-in checks are reported as skipped and you are pointed to the portal.
      - Entra keeps audit and sign-in logs 7 days on Free, 30 days on P1/P2.
        Activity on 2026-10-13 ages out of a P1/P2 tenant on 2026-11-12.
      - PIM-eligible role checks need Entra ID P2.

    Permissions: the signed-in account needs Global Reader (or Security Reader
    plus Reports Reader) or Global Administrator in each customer tenant. The
    Microsoft Graph Command Line Tools app must be consented in the customer
    tenant, or pass -ClientId for your own multi-tenant app.

.PARAMETER TenantId
    One or more customer tenant IDs or domains (contoso.onmicrosoft.com).
    Omit to audit the tenant of the account you sign in with.

.PARAMETER TenantListPath
    A CSV with a TenantId column (and optional Name column), or a text file
    with one tenant ID or domain per line.

.PARAMETER AllCustomers
    Sign in to your partner tenant and audit every GDAP customer listed there.

.PARAMETER Since
    Start of the review window. Default 2026-10-13 00:00 UTC, the first
    activity Huntress reported.

.PARAMETER OutputPath
    Folder for the CSV and HTML report. Default C:\temp\ConnectWise IOC Audit <timestamp>.

.PARAMETER MaxSignInPages
    Cap on pages (up to 500 rows each) read per sign-in query. The backup app
    can sign in thousands of times a week in a tenant that uses it, and each page
    takes several seconds. Default 10. Queries for the IOC IPs return only matching
    rows, so a low cap rarely limits them.

.PARAMETER ClientId
    Optional app ID to sign in with instead of Microsoft Graph Command Line Tools.

.PARAMETER UseDeviceCode
    Sign in with a device code instead of a browser window.

.EXAMPLE
    & '.\Audit ConnectWise SkyKick IOCs.ps1'
    Audits the tenant of the account you sign in with.

.EXAMPLE
    & '.\Audit ConnectWise SkyKick IOCs.ps1' -TenantId contoso.onmicrosoft.com, 1b2c3d4e-0000-0000-0000-000000000000
    Audits two customer tenants, signing in to each in turn.

.EXAMPLE
    & '.\Audit ConnectWise SkyKick IOCs.ps1' -AllCustomers
    Audits every GDAP customer of your partner tenant.

.NOTES
    Name:    Audit ConnectWise SkyKick IOCs
    Author:  Brad Brown, Systems Administrator
    Context: Technician workstation (interactive), PowerShell 5.1 or 7+
    Module:  Microsoft.Graph.Authentication (installed if missing)
#>

[CmdletBinding(DefaultParameterSetName = 'Tenants')]
param(
    [Parameter(ParameterSetName = 'Tenants')]
    [string[]]$TenantId,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [string]$TenantListPath,

    [Parameter(ParameterSetName = 'Partner', Mandatory)]
    [switch]$AllCustomers,

    [datetime]$Since = [datetime]::new(2026, 10, 13, 0, 0, 0, [DateTimeKind]::Utc),

    [string]$OutputPath = "C:\temp\ConnectWise IOC Audit $(Get-Date -Format 'yyyy-MM-dd HHmm')",

    [ValidateRange(1, 500)]
    [int]$MaxSignInPages = 10,

    [string]$ClientId,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region Indicators (from the Huntress write-up)

$IocApps = [ordered]@{
    '506e08f9-6e9a-4da4-942b-a099a03644ae' = @{ Name = 'ConnectWise Cloud Backup (formerly SkyKick)';         Note = 'its credential was abused' }
    '24205314-2b89-4e07-a2a4-579e898a5640' = @{ Name = 'ConnectWise Cloud Management - MS Teams';            Note = 'added itself to Global Administrator and added secrets to other apps' }
    'b78f6a77-d4e5-46fb-87e5-d1648bd02519' = @{ Name = 'ConnectWise Cloud Management - Exchange Online';     Note = 'reported abused' }
    'b2b55f5b-7758-4719-8d8f-88ae172e6bdb' = @{ Name = 'ConnectWise Cloud Management - SharePoint Online';   Note = 'reported abused' }
    '2399d300-6fca-4e6a-a686-399fefe75b83' = @{ Name = 'ConnectWise Cloud Management';                      Note = 'listed for review' }
    '0de14c77-b9b0-4137-9360-34878a929827' = @{ Name = 'ConnectWise Cloud Management - MS Graph';            Note = 'listed for review' }
    '412dcf96-176d-4b3a-a1b0-4981ad66971e' = @{ Name = 'ConnectWise Cloud Management - Partner Center';      Note = 'listed for review' }
}
$VendorOwnerTenantId = '3f9cd7a0-127a-4ed4-bf06-2f830d5616b7'

$IocIps = @{
    '144.172.64.128' = 'Actor IP (AS14956 RouterHosting): password spray and Cloud Backup token requests'
    '144.172.64.99'  = 'Suspicious IP shared by ConnectWise'
    '144.172.64.60'  = 'Suspicious IP shared by ConnectWise'
}
# Microsoft-internal ULA range; legitimate ConnectWise traffic also comes from it, so low fidelity alone
$IocIpv6Prefix = 'fde4:8dba:2600:37ce:6d26:200:a76:'

# All low fidelity on their own; they raise confidence when combined with an app actor or IOC IP
$IocUserAgents = @('Python-urllib/3.12', 'python-requests/2.31', 'curl/7.88.1')

# Built-in role template IDs worth flagging on a service principal
$PrivilegedRoles = @{
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
    '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' = 'Privileged Authentication Administrator'
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
    '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
    '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
    '69091246-20e8-4a56-aa4d-066075b2a7a8' = 'Teams Administrator'
    'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
    '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
    '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2' = 'Hybrid Identity Administrator'
    'c4e39bd9-1100-46d3-8c65-fb160da0071f' = 'Authentication Administrator'
    'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' = 'Conditional Access Administrator'
    '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'
    '9360feb5-f418-4baa-8175-e2a00bac4301' = 'Directory Writers'
}

# App inventory: tenants that publish Microsoft's own apps (excluded from the third-party list)
$MicrosoftOwnerTenants = @('f8cdef31-a31e-4b4a-93e4-5f571e91255a', '72f988bf-86f1-41af-91ab-2d7cd011db47')

# Resource APIs whose application permissions are listed per app
$PermissionResources = [ordered]@{
    '00000003-0000-0000-c000-000000000000' = 'Microsoft Graph'
    '00000002-0000-0ff1-ce00-000000000000' = 'Exchange Online'
    '00000003-0000-0ff1-ce00-000000000000' = 'SharePoint'
    '00000002-0000-0000-c000-000000000000' = 'Azure AD Graph (legacy)'
    '00000007-0000-0ff1-ce00-000000000000' = 'Exchange Online Protection'
}

# Application or admin-consented delegated permissions that give broad data or directory access
$HighRiskPermissions = @(
    'Mail.Read', 'Mail.ReadWrite', 'Mail.Send', 'MailboxSettings.ReadWrite', 'full_access_as_app', 'full_access_as_user',
    'EWS.AccessAsUser.All', 'Exchange.ManageAsApp', 'Calendars.ReadWrite', 'Contacts.ReadWrite',
    'Files.Read.All', 'Files.ReadWrite.All', 'Sites.Read.All', 'Sites.ReadWrite.All', 'Sites.Manage.All', 'Sites.FullControl.All',
    'Chat.Read.All', 'Chat.ReadWrite.All', 'ChannelMessage.Read.All',
    'Directory.ReadWrite.All', 'Directory.AccessAsUser.All', 'User.ReadWrite.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All',
    'Application.ReadWrite.All', 'Application.ReadWrite.OwnedBy', 'AppRoleAssignment.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All',
    'RoleManagement.ReadWrite.Directory', 'UserAuthenticationMethod.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess',
    'Policy.ReadWrite.AuthenticationMethod', 'Domain.ReadWrite.All', 'Organization.ReadWrite.All', 'ServicePrincipalEndpoint.ReadWrite.All'
)

#endregion

$Scopes = @(
    'Application.Read.All'
    'Directory.Read.All'
    'RoleManagement.Read.Directory'
    'AuditLog.Read.All'
    'Policy.Read.All'
)

#region Helpers

function Get-GraphPaged {
    # Follows @odata.nextLink. -MaxPages 0 = unlimited. Returns the rows and whether the cap cut it short.
    # -Activity prints a live page counter, since sign-in and audit queries can take minutes.
    param([string]$Uri, [int]$MaxPages = 0, [string]$Activity)
    $rows  = [System.Collections.Generic.List[object]]::new()
    $page  = 0
    $next  = $Uri
    $truncated = $false
    $cap = if ($MaxPages -gt 0) { "/$MaxPages" } else { '' }
    $width = 0   # longest progress line so far, so the final line fully overwrites it
    while ($next) {
        if ($Activity) {
            $line  = "    {0}: page {1}{2}, {3} rows so far" -f $Activity, ($page + 1), $cap, $rows.Count
            $width = [math]::Max($width, $line.Length)
            Write-Host ("`r" + $line) -NoNewline -ForegroundColor DarkGray
        }
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable
        if ($resp.value) { foreach ($r in $resp.value) { $rows.Add($r) } }
        $next = $resp.'@odata.nextLink'
        $page++
        if ($MaxPages -gt 0 -and $page -ge $MaxPages -and $next) { $truncated = $true; break }
    }
    if ($Activity) {
        $line = "    {0}: {1} rows{2}" -f $Activity, $rows.Count, $(if ($truncated) { " (stopped at $MaxPages pages)" })
        Write-Host ("`r" + $line.PadRight($width)) -ForegroundColor DarkGray
    }
    [pscustomobject]@{ Rows = $rows; Truncated = $truncated }
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Format-Utc { param($Value) $d = ConvertTo-UtcDate $Value; if ($d) { $d.ToString('yyyy-MM-dd HH:mm') + ' UTC' } }

function Get-ErrorText {
    param($ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $msg = $ErrorRecord.ErrorDetails.Message }
    ($msg -replace '\s+', ' ').Trim()
}

function Test-IocUserAgent {
    param([string]$UserAgent)
    if (-not $UserAgent) { return $null }
    foreach ($ua in $IocUserAgents) { if ($UserAgent -like "*$ua*") { return $ua } }
    $null
}

#endregion

#region Portal links
# The #@<tenant>/ prefix makes the Azure portal switch to that directory, which is what you want with GDAP.

function Get-PortalBase { "https://portal.azure.com/#@$($script:Tenant.Id)/view" }

function Get-EnterpriseAppUrl {
    param([string]$ObjectId, [string]$AppId, [string]$Blade = 'Overview')
    "$(Get-PortalBase)/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/$Blade/objectId/$ObjectId/appId/$AppId"
}
function Get-AppRegistrationUrl {
    param([string]$AppId, [string]$Blade = 'Credentials')
    "$(Get-PortalBase)/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/$Blade/appId/$AppId/isMSAApp~/false"
}
function Get-RoleMembersUrl {
    param([string]$RoleDefinitionId, [string]$RoleName)
    "$(Get-PortalBase)/Microsoft_AAD_IAM/RoleMenuBlade/~/RoleMembers/objectId/$RoleDefinitionId/roleName/$([uri]::EscapeDataString($RoleName))/roleTemplateId/$RoleDefinitionId/adminUnitObjectId//customRole~/false/resourceScope/%2F"
}
function Get-CaPolicyUrl { param([string]$PolicyId) "$(Get-PortalBase)/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/$PolicyId" }
function Get-AuditLogUrl { "$(Get-PortalBase)/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Audit" }
function Get-SignInLogUrl { "$(Get-PortalBase)/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/SignIns" }

#endregion

#region Findings

$Findings = [System.Collections.Generic.List[object]]::new()
$AppInventory = [System.Collections.Generic.List[object]]::new()
$SeverityOrder = @{ Critical = 0; High = 1; Review = 2; Info = 3 }

function Add-Finding {
    param(
        [ValidateSet('Critical', 'High', 'Review', 'Info')][string]$Severity,
        [string]$Category,
        [string]$Object,
        [string]$Detail,
        [string]$WhereToLook,
        [string]$PortalUrl,
        [string]$Action,
        [string]$When
    )
    $Findings.Add([pscustomobject]@{
        Tenant      = $script:Tenant.Name
        TenantId    = $script:Tenant.Id
        Severity    = $Severity
        Category    = $Category
        Object      = $Object
        Detail      = $Detail
        When        = $When
        WhereToLook = $WhereToLook
        PortalUrl   = $PortalUrl
        Action      = $Action
    })
}

#endregion

#region Checks

function Test-VendorApps {
    # Returns the vendor service principals found so later checks can use them
    $found = @{}
    # Filtered here rather than in Graph: Graph rejects $filter on appOwnerOrganizationId (Request_UnsupportedQuery).
    # Matches the listed app IDs, anything else the vendor tenant publishes, and the names
    # older tenants show ("SkyKick Cloud Manager").
    $all = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id,appId,displayName,accountEnabled,appOwnerOrganizationId,servicePrincipalType,publisherName,verifiedPublisher,appRoles&$top=999' -Activity 'Enterprise apps').Rows
    $script:AllSps = $all   # reused by the app inventory
    foreach ($sp in $all) {
        if (-not $sp.id) { continue }
        if (($sp.appId -and $IocApps.Contains([string]$sp.appId)) -or
            $sp.appOwnerOrganizationId -eq $VendorOwnerTenantId -or
            $sp.displayName -match 'SkyKick|ConnectWise') { $found[$sp.id] = $sp }
    }

    if ($found.Count -eq 0) {
        Add-Finding -Severity Info -Category 'Vendor apps' -Object 'ConnectWise / SkyKick' `
            -Detail 'No ConnectWise or SkyKick enterprise apps in this tenant. Credential, audit and sign-in checks still run.' `
            -WhereToLook 'Entra admin center > Enterprise apps > All applications > search "SkyKick" / "ConnectWise"' `
            -PortalUrl "$(Get-PortalBase)/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview"
        return $found
    }

    foreach ($sp in $found.Values) {
        $listed = $sp.appId -and $IocApps.Contains([string]$sp.appId)
        $why    = if ($listed) { "On the Huntress list: $($IocApps[$sp.appId].Note)" } else { 'Not on the Huntress list, but published by the same vendor or named like it' }
        $owner  = if ($sp.appOwnerOrganizationId -eq $VendorOwnerTenantId) { 'owner tenant matches ConnectWise' } else { "owner tenant $($sp.appOwnerOrganizationId)" }
        $where  = "Entra admin center > Enterprise apps > $($sp.displayName) > Properties > Enabled for users to sign-in?"

        if ($sp.accountEnabled) {
            Add-Finding -Severity ($(if ($listed) { 'High' } else { 'Review' })) -Category 'Vendor apps' `
                -Object "$($sp.displayName) ($($sp.appId))" `
                -Detail "ENABLED. $why; $owner." `
                -WhereToLook $where -PortalUrl (Get-EnterpriseAppUrl $sp.id $sp.appId 'Properties') `
                -Action 'Set "Enabled for users to sign-in?" to No and Save. DISABLE, do not delete (deleting removes consent). Leave disabled until ConnectWise confirms credentials are reset. Backups pause while disabled.'
        } else {
            Add-Finding -Severity Info -Category 'Vendor apps' `
                -Object "$($sp.displayName) ($($sp.appId))" `
                -Detail "Already disabled. $why; $owner." `
                -WhereToLook $where -PortalUrl (Get-EnterpriseAppUrl $sp.id $sp.appId 'Properties') `
                -Action 'None. Disabling does not remove credentials already added elsewhere; review the credential findings.'
        }
    }
    $found
}

function Test-RoleAssignments {
    param([hashtable]$VendorSps)

    $assignments = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$select=id,principalId,roleDefinitionId,directoryScopeId').Rows
    $eligible = @()
    try {
        $eligible = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$select=id,principalId,roleDefinitionId,directoryScopeId').Rows
    } catch {
        Write-Verbose "PIM eligibility not readable (needs Entra ID P2): $(Get-ErrorText $_)"
    }

    $all = @($assignments | ForEach-Object { $_['__kind'] = 'Active'; $_ }) + @($eligible | ForEach-Object { $_['__kind'] = 'Eligible (PIM)'; $_ })
    if (-not $all) { return }

    # Resolve principals in batches of 1,000 to find which are service principals
    $ids  = @($all | ForEach-Object { $_.principalId } | Sort-Object -Unique)
    $objs = @{}
    for ($i = 0; $i -lt $ids.Count; $i += 1000) {
        $chunk = $ids[$i..([math]::Min($i + 999, $ids.Count - 1))]
        $body  = @{ ids = $chunk; types = @('servicePrincipal') } | ConvertTo-Json
        $resp  = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body $body -ContentType 'application/json' -OutputType Hashtable
        foreach ($o in $resp.value) { $objs[$o.id] = $o }
    }

    $roleNames = @{}
    foreach ($a in $all) {
        $sp = $objs[$a.principalId]
        if (-not $sp) { continue }   # users and groups are out of scope here

        $roleId = $a.roleDefinitionId
        if (-not $roleNames.ContainsKey($roleId)) {
            $roleNames[$roleId] = if ($PrivilegedRoles.ContainsKey($roleId)) { $PrivilegedRoles[$roleId] } else {
                try { (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$roleId`?`$select=displayName" -OutputType Hashtable).displayName } catch { $roleId }
            }
        }
        $roleName = $roleNames[$roleId]
        $isVendor = $VendorSps.ContainsKey($sp.id) -or $sp.appOwnerOrganizationId -eq $VendorOwnerTenantId
        $isPriv   = $PrivilegedRoles.ContainsKey($roleId)
        if (-not $isVendor -and -not $isPriv) { continue }

        $scope = if ($a.directoryScopeId -and $a.directoryScopeId -ne '/') { " scoped to $($a.directoryScopeId)" } else { '' }
        $where = "Entra admin center > Roles & admins > $roleName > Assignments ($($a.__kind)) > $($sp.displayName)"
        $url   = Get-RoleMembersUrl $roleId $roleName

        if ($isVendor) {
            Add-Finding -Severity Critical -Category 'Directory roles' `
                -Object "$($sp.displayName) ($($sp.appId))" `
                -Detail "ConnectWise/SkyKick app holds $roleName ($($a.__kind))$scope. Huntress saw these apps assign themselves Exchange Administrator and Global Administrator." `
                -WhereToLook $where -PortalUrl $url `
                -Action 'Unless you intentionally granted this role, select the app on the role''s Assignments page and Remove assignment. Then check the audit log findings for who added it and when.'
        } else {
            Add-Finding -Severity Review -Category 'Directory roles' `
                -Object "$($sp.displayName) ($($sp.appId))" `
                -Detail "Service principal holds privileged role $roleName ($($a.__kind))$scope. Not a ConnectWise app; confirm it is expected." `
                -WhereToLook $where -PortalUrl $url `
                -Action 'Confirm the app is known and needs this role. Remove the assignment if not.'
        }
    }
}

function Test-NewCredentials {
    param([hashtable]$CredentialActors)
    # $CredentialActors: targetObjectId -> audit description, filled by the audit check so findings can be correlated

    $sinceUtc = $Since.ToUniversalTime()
    $apps = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials,keyCredentials&$top=999' -Activity 'App registrations').Rows
    $sps  = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id,appId,displayName,passwordCredentials,keyCredentials,servicePrincipalType,preferredSingleSignOnMode&$top=999' -Activity 'Enterprise apps').Rows

    $count = 0
    foreach ($kind in 'Application', 'ServicePrincipal') {
        $objects = if ($kind -eq 'Application') { $apps } else { $sps }
        foreach ($o in $objects) {
            $creds = @()
            foreach ($c in @($o.passwordCredentials)) { if ($c) { $creds += [pscustomobject]@{ Type = 'Client secret'; Cred = $c } } }
            foreach ($c in @($o.keyCredentials))      { if ($c) { $creds += [pscustomobject]@{ Type = "Certificate ($($c.usage))"; Cred = $c } } }

            foreach ($entry in $creds) {
                $c = $entry.Cred
                $start = ConvertTo-UtcDate $c.startDateTime
                if (-not $start -or $start -lt $sinceUtc) { continue }
                $count++
                $end    = ConvertTo-UtcDate $c.endDateTime
                $label  = if ($c.displayName) { "'$($c.displayName)'" } else { '(no description)' }
                $hint   = if ($c.hint) { ", value starts '$($c.hint)'" } else { '' }
                $notes  = @()
                if ($end -and $end.Year -eq 2028) { $notes += 'expires in 2028, matching the secrets the actor added' }
                if ($CredentialActors.ContainsKey($o.id)) { $notes += "audit log: $($CredentialActors[$o.id])" }

                $sev = 'High'
                if ($CredentialActors.ContainsKey($o.id) -and $CredentialActors[$o.id] -match ' by (IOC app|an app) ') { $sev = 'Critical' }
                # Recently-rotated SAML signing certs on gallery SSO apps are normal churn
                if ($kind -eq 'ServicePrincipal' -and $entry.Type -like 'Certificate (Sign)*' -and $o.preferredSingleSignOnMode -eq 'saml' -and $sev -ne 'Critical') { $sev = 'Review' }

                $detail = "$($entry.Type) $label added $(Format-Utc $start)$hint, expires $(Format-Utc $end), keyId $($c.keyId)."
                if ($notes) { $detail += ' ' + ($notes -join '; ') + '.' }

                if ($kind -eq 'Application') {
                    Add-Finding -Severity $sev -Category 'New credentials' `
                        -Object "App registration: $($o.displayName) ($($o.appId))" -Detail $detail -When (Format-Utc $start) `
                        -WhereToLook "Entra admin center > App registrations > All applications > $($o.displayName) > Certificates & secrets" `
                        -PortalUrl (Get-AppRegistrationUrl $o.appId) `
                        -Action "If nobody on your team created this $($entry.Type.ToLower()), delete it on the Certificates & secrets page (match the description/keyId), then rotate any secret the app legitimately uses."
                } elseif ($entry.Type -eq 'Client secret' -or $entry.Type -like 'Certificate (Verify)*') {
                    Add-Finding -Severity $sev -Category 'New credentials' `
                        -Object "Enterprise app: $($o.displayName) ($($o.appId))" -Detail ($detail + ' This credential is on the service principal itself and is NOT shown in the portal.') -When (Format-Utc $start) `
                        -WhereToLook "Not visible in the UI. Review in Graph Explorer: GET https://graph.microsoft.com/v1.0/servicePrincipals/$($o.id)?`$select=passwordCredentials,keyCredentials" `
                        -PortalUrl (Get-EnterpriseAppUrl $o.id $o.appId) `
                        -Action "If unexpected, remove it with Graph (not run by this script): Remove-MgServicePrincipalPassword -ServicePrincipalId $($o.id) -KeyId $($c.keyId)  (for a certificate, PATCH keyCredentials without it). Or disable the app under Properties."
                } else {
                    Add-Finding -Severity $sev -Category 'New credentials' `
                        -Object "Enterprise app: $($o.displayName) ($($o.appId))" -Detail $detail -When (Format-Utc $start) `
                        -WhereToLook "Entra admin center > Enterprise apps > $($o.displayName) > Single sign-on > SAML Certificates" `
                        -PortalUrl (Get-EnterpriseAppUrl $o.id $o.appId 'SingleSignOn') `
                        -Action 'Confirm the certificate rotation was planned. Delete it if not.'
                }
            }
        }
    }
    if ($count -eq 0) {
        Add-Finding -Severity Info -Category 'New credentials' -Object 'All app registrations and enterprise apps' `
            -Detail "No secrets or certificates with a start date on or after $(Format-Utc $Since) ($($apps.Count) app registrations, $($sps.Count) enterprise apps checked)." `
            -WhereToLook 'Entra admin center > App registrations > All applications' -PortalUrl "$(Get-PortalBase)/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
    }
}

function Test-AuditLog {
    # Returns targetObjectId -> description for credential changes, used to correlate with Test-NewCredentials
    $sinceIso = $Since.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $credentialActors = @{}
    $events = [System.Collections.Generic.List[object]]::new()

    foreach ($category in 'RoleManagement', 'ApplicationManagement') {
        $r = Get-GraphPaged "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=activityDateTime ge $sinceIso and category eq '$category'&`$top=999" -Activity "$category events"
        foreach ($e in $r.Rows) { $events.Add($e) }
    }

    $roleAdd   = '^Add (eligible )?member to role'
    $credAdd   = 'Certificates and secrets management|Add service principal credentials'
    # "Update service principal/application" fires for many routine reasons; it only counts as a
    # credential change when the modified properties say so
    $credProps = 'KeyDescription|KeyCredentials|PasswordCredentials|FederatedIdentityCredentials'

    # Microsoft's own services (e.g. SharePoint Online maintaining its helper apps) are not "an app" in the
    # sense that matters here. Their audit entries often have no appId, so look them up by object ID.
    $msSpIds = @{}
    foreach ($sp in @($script:AllSps)) {
        if ($sp.id -and $MicrosoftOwnerTenants -contains [string]$sp.appOwnerOrganizationId) { $msSpIds[$sp.id] = $true }
    }
    $consent   = '^Consent to application|^Add app role assignment to service principal|^Add delegated permission grant|^Add OAuth2PermissionGrant'
    $appChange = '^Update application|^Add owner to (application|service principal)|^Add application|^Add service principal'

    $hits = 0
    foreach ($e in $events) {
        $act      = [string]$e.activityDisplayName
        $app      = $e.initiatedBy.app
        $user     = $e.initiatedBy.user
        $byApp    = $app -and ($app.appId -or $app.servicePrincipalId)
        $actorId  = if ($byApp) { $app.appId } else { $null }
        $isIocApp = $actorId -and $IocApps.Contains($actorId)
        $isMsApp  = $byApp -and -not $actorId -and (
                        ($app.servicePrincipalId -and $msSpIds.ContainsKey($app.servicePrincipalId)) -or
                        (-not $script:AllSps -and $app.displayName -match '^(Office 365|Microsoft|Windows Azure|Azure)'))
        $actorRef = if ($app.appId) { $app.appId } else { "object $($app.servicePrincipalId)" }
        $actor    = if ($byApp) { "app $($app.displayName) ($actorRef)" } elseif ($user) { "user $($user.userPrincipalName) from $($user.ipAddress)" } else { 'unknown actor' }

        $ua = ($e.additionalDetails | Where-Object { $_.key -eq 'User-Agent' } | Select-Object -First 1).value
        $iocUa = Test-IocUserAgent $ua
        $userIp = if ($user) { [string]$user.ipAddress } else { '' }
        $iocIp = $userIp -and $IocIps.ContainsKey($userIp)

        $target   = @($e.targetResources) | Select-Object -First 1
        $targetNm = if ($target.displayName) { $target.displayName } elseif ($target.userPrincipalName) { $target.userPrincipalName } else { $target.id }
        # For role adds the role name sits in modifiedProperties
        $roleProp = @($target.modifiedProperties) | Where-Object { $_.displayName -eq 'Role.DisplayName' } | Select-Object -First 1
        $roleName = if ($roleProp) { ([string]$roleProp.newValue).Trim('"') } else { '' }

        $propNames = (@($target.modifiedProperties) | ForEach-Object { $_.displayName }) -join ' '
        $isCred = $act -match $credAdd -or ($act -match '^Update (service principal|application)' -and $propNames -match $credProps)

        $sev = $null; $why = $null
        $self = $byApp -and $app.servicePrincipalId -and $target.id -eq $app.servicePrincipalId
        if ($isIocApp)                       { $sev = 'Critical'; $why = 'performed by a ConnectWise/SkyKick app on the Huntress list' + $(if ($self -and $act -match $roleAdd) { ' - it added ITSELF to the role' }) }
        elseif ($iocIp)                      { $sev = 'Critical'; $why = "performed from IOC IP $userIp" }
        elseif ($isMsApp -and -not $iocUa)  { continue }   # routine Microsoft service activity
        elseif ($byApp -and $act -match $roleAdd) {
            $sev  = 'High'; $why = $(if ($self) { 'an app added ITSELF to a directory role' } else { 'an app assigned a directory role' })
        }
        elseif ($byApp -and $isCred)              { $sev = 'High';   $why = 'an app added credentials to an app' }
        elseif ($byApp -and $act -match $consent) { $sev = 'Review'; $why = 'an app granted permissions or consent' }
        elseif ($isCred)                          { $sev = 'Review'; $why = 'credential change on an app; confirm a team member made it' }
        elseif ($act -match $roleAdd -and $roleName -and $PrivilegedRoles.Values -contains $roleName) { $sev = 'Review'; $why = 'privileged role assigned' }
        elseif ($byApp -and $act -match $appChange) { $sev = 'Review'; $why = 'an app modified an application' }

        if ($iocUa) {
            if (-not $sev) { $sev = 'Review'; $why = 'IOC user agent (low fidelity alone)' }
            elseif ($sev -eq 'Review') { $sev = 'High' }
            $why += "; user agent $iocUa"
        }
        if (-not $sev) { continue }

        if ($isCred -and $target.id) {
            $tag = if ($isIocApp) { "IOC app $actor" } elseif ($byApp) { "an app ($actor)" } else { $actor }
            $credentialActors[$target.id] = "'$($act.Trim())' $(Format-Utc $e.activityDateTime) by $tag"
        }

        $hits++
        $roleText = if ($roleName) { " (role: $roleName)" } else { '' }
        $result   = if ($e.result -and $e.result -ne 'success') { " Result: $($e.result) $($e.resultReason)." } else { '' }
        Add-Finding -Severity $sev -Category 'Audit log' `
            -Object "$($act.Trim()) -> $targetNm$roleText" `
            -Detail "By $actor; $why.$result User-Agent: $(if ($ua) { $ua } else { 'n/a' }). Correlation ID $($e.correlationId)." `
            -When (Format-Utc $e.activityDateTime) `
            -WhereToLook "Entra admin center > Monitoring & health > Audit logs > Date: custom ($(Format-Utc $e.activityDateTime)), Activity: '$act', or filter Correlation ID $($e.correlationId)" `
            -PortalUrl (Get-AuditLogUrl) `
            -Action $(if ($act -match $roleAdd) { 'Remove the role assignment if not intended (see Directory roles findings).' }
                      elseif ($isCred) { 'Find the credential under the target app''s Certificates & secrets and delete it if not created by your team.' }
                      else { 'Confirm the change was expected. Revert in the target app if not.' })
    }

    if ($hits -eq 0) {
        Add-Finding -Severity Info -Category 'Audit log' -Object 'Role and application management events' `
            -Detail "$($events.Count) role/application events since $(Format-Utc $Since); none performed by an app, from an IOC IP, or with an IOC user agent. Free tenants keep only 7 days." `
            -WhereToLook 'Entra admin center > Monitoring & health > Audit logs' -PortalUrl (Get-AuditLogUrl)
    }
    $credentialActors
}

function Add-SignInFindings {
    param($Rows, [string]$Label, [bool]$Truncated)
    # Group to keep the report readable: one finding per app/user + IP + UA + outcome
    $groups = $Rows | Group-Object -Property {
        $who = if ($_.servicePrincipalId -or $_.signInEventTypes -contains 'servicePrincipal') { "app $($_.appDisplayName) ($($_.appId))" } else { "user $($_.userPrincipalName) -> $($_.appDisplayName)" }
        $ok  = if ($_.status.errorCode -eq 0) { 'SUCCESS' } else { "failed $($_.status.errorCode)" }
        "$who|$($_.ipAddress)|$ok|$($_.userAgent)"
    }

    foreach ($g in $groups) {
        $first = $g.Group | Sort-Object { ConvertTo-UtcDate $_.createdDateTime } | Select-Object -First 1
        $last  = $g.Group | Sort-Object { ConvertTo-UtcDate $_.createdDateTime } | Select-Object -Last 1
        $who, $ip, $ok, $ua = $g.Name -split '\|', 4
        $iocUa  = Test-IocUserAgent $ua
        $isApp  = $who -like 'app *'
        $listed = $isApp -and $IocApps.Contains([string]$first.appId)

        $ipNote = $null
        if ($IocIps.ContainsKey($ip))          { $ipNote = $IocIps[$ip] }
        elseif ($ip -like "$IocIpv6Prefix*")   { $ipNote = 'Microsoft-internal IPv6 range Huntress saw on the second app connection (legitimate traffic also uses it)' }

        if     ($IocIps.ContainsKey($ip))                    { $sev = $(if ($ok -eq 'SUCCESS') { 'Critical' } else { 'High' }) }
        elseif ($ipNote -or $iocUa)                          { $sev = 'Review' }
        elseif ($listed)                                     { $sev = 'Info' }
        else                                                 { $sev = 'Review' }

        $detail = "$($g.Count) $Label sign-in(s), $ok, from $ip"
        if ($ipNote) { $detail += " ($ipNote)" }
        $detail += ". User-Agent: $(if ($ua) { $ua } else { 'n/a' })$(if ($iocUa) { ' (IOC user agent)' })."
        $detail += " First $(Format-Utc $first.createdDateTime), last $(Format-Utc $last.createdDateTime). Example request ID $($first.id)."
        if ($sev -eq 'Info') { $detail += ' Source IP is not an IOC; confirm it belongs to Microsoft/Azure or ConnectWise.' }

        $tab = if ($isApp) { 'Service principal sign-ins' } elseif ($first.isInteractive) { 'User sign-ins (interactive)' } else { 'User sign-ins (non-interactive)' }
        $filter = if ($isApp) { "Application ID $($first.appId)" } else { "User $($first.userPrincipalName)" }
        Add-Finding -Severity $sev -Category 'Sign-ins' -Object $who -Detail $detail -When (Format-Utc $first.createdDateTime) `
            -WhereToLook "Entra admin center > Monitoring & health > Sign-in logs > $tab > filter $filter, IP $ip, Date from $(Format-Utc $Since)" `
            -PortalUrl (Get-SignInLogUrl) `
            -Action $(if ($isApp -and $sev -in 'Critical', 'High') { 'Disable the app (Enterprise apps > Properties). Treat the tenant as accessed: review the audit log and new credentials findings and open an incident.' }
                      elseif (-not $isApp -and $sev -in 'Critical', 'High') { 'Reset the user''s password, revoke sessions (Users > user > Revoke sessions), confirm MFA, and review their recent activity.' }
                      else { 'Confirm the source is expected.' })
    }
    if ($Truncated) {
        Add-Finding -Severity Info -Category 'Sign-ins' -Object $Label `
            -Detail "Stopped after $MaxSignInPages pages; more sign-ins exist. Re-run with a higher -MaxSignInPages or review in the portal." `
            -WhereToLook 'Entra admin center > Monitoring & health > Sign-in logs' -PortalUrl (Get-SignInLogUrl)
    }
}

function Test-SignIns {
    param([hashtable]$VendorSps, [bool]$VendorListKnown)
    $sinceIso = $Since.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    # Service principal sign-ins are only exposed through the beta endpoint
    $base = 'https://graph.microsoft.com/beta/auditLogs/signIns'

    # An app cannot sign in to a tenant it has no service principal in, so only query the
    # ConnectWise apps present here; these queries are slow. If the app list could not be read,
    # fall back to every listed app. The IOC IP queries below run regardless.
    $targets = [ordered]@{}
    if ($VendorListKnown) {
        foreach ($sp in $VendorSps.Values) { $targets[[string]$sp.appId] = $sp.displayName }
    } else {
        foreach ($appId in $IocApps.Keys) { $targets[$appId] = $IocApps[$appId].Name }
    }

    try {
        # Every app sign-in for the ConnectWise apps
        foreach ($appId in $targets.Keys) {
            $r = Get-GraphPaged "$base`?`$filter=createdDateTime ge $sinceIso and appId eq '$appId' and signInEventTypes/any(t: t eq 'servicePrincipal')&`$top=500" -MaxPages $MaxSignInPages -Activity $targets[$appId]
            if ($r.Rows.Count) { Add-SignInFindings -Rows $r.Rows -Label "service principal ($($targets[$appId]))" -Truncated $r.Truncated }
        }
        if ($VendorListKnown -and $targets.Count -eq 0) {
            Write-Host '    No ConnectWise/SkyKick apps in this tenant; skipping their sign-in queries.' -ForegroundColor DarkGray
        }

        # Anything at all from the IOC IPs (password spray against users, other apps)
        $ipHits = 0
        foreach ($ip in $IocIps.Keys) {
            foreach ($type in 'interactiveUser', 'nonInteractiveUser', 'servicePrincipal', 'managedIdentity') {
                $r = Get-GraphPaged "$base`?`$filter=createdDateTime ge $sinceIso and ipAddress eq '$ip' and signInEventTypes/any(t: t eq '$type')&`$top=500" -MaxPages $MaxSignInPages -Activity "$ip $type"
                # The ConnectWise app sign-ins were already reported above
                $rows = @($r.Rows | Where-Object { -not ($type -eq 'servicePrincipal' -and $IocApps.Contains([string]$_.appId)) })
                if ($rows.Count) { $ipHits += $rows.Count; Add-SignInFindings -Rows $rows -Label $type -Truncated $r.Truncated }
            }
        }
        Add-Finding -Severity Info -Category 'Sign-ins' -Object 'IOC IP addresses' `
            -Detail "$(if ($ipHits) { "$ipHits" } else { 'No' }) user/app sign-ins from $($IocIps.Keys -join ', ') outside the ConnectWise app findings since $(Format-Utc $Since)." `
            -WhereToLook 'Entra admin center > Monitoring & health > Sign-in logs > each tab > Add filter: IP address' -PortalUrl (Get-SignInLogUrl)
    } catch {
        $msg = Get-ErrorText $_
        if ($msg -match 'NonPremium|RequestFromNonPremiumTenant|premium') {
            Add-Finding -Severity Review -Category 'Sign-ins' -Object 'Sign-in logs' `
                -Detail 'Tenant has no Entra ID P1/P2, so sign-in logs cannot be read through Graph. The portal shows the last 7 days only.' `
                -WhereToLook "Entra admin center > Monitoring & health > Sign-in logs > Service principal sign-ins > filter Application ID 506e08f9-6e9a-4da4-942b-a099a03644ae; User sign-ins > filter IP 144.172.64.128" `
                -PortalUrl (Get-SignInLogUrl) -Action 'Check manually in the portal, or in the Purview unified audit log.'
        } else { throw }
    }
}

function Test-ConditionalAccess {
    param([hashtable]$VendorSps)
    $policies = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies').Rows
    $vendorAppIds = @($IocApps.Keys) + @($VendorSps.Values | ForEach-Object { $_.appId }) | Sort-Object -Unique
    $vendorSpIds  = @($VendorSps.Keys)
    $hits = 0

    foreach ($p in $policies) {
        $excludedApps = @($p.conditions.applications.excludeApplications) | Where-Object { $vendorAppIds -contains $_ }
        $excludedSps  = @($p.conditions.clientApplications.excludeServicePrincipals) | Where-Object { $vendorSpIds -contains $_ -or $vendorAppIds -contains $_ }
        $includedSps  = @($p.conditions.clientApplications.includeServicePrincipals) | Where-Object { $vendorSpIds -contains $_ -or $vendorAppIds -contains $_ -or $_ -eq 'ServicePrincipalsInMyTenant' }

        foreach ($x in @($excludedApps) + @($excludedSps)) {
            if (-not $x) { continue }
            $hits++
            $name = if ($IocApps.Contains($x)) { $IocApps[$x].Name } else { ($VendorSps.Values | Where-Object { $_.id -eq $x -or $_.appId -eq $x } | Select-Object -First 1).displayName }
            Add-Finding -Severity High -Category 'Conditional Access' -Object "Policy: $($p.displayName) ($($p.state))" `
                -Detail "Excludes $name ($x). An exclusion lets the app bypass this policy, e.g. a location block." `
                -WhereToLook "Entra admin center > Conditional Access > Policies > $($p.displayName) > Target resources / Workload identities > Exclude" `
                -PortalUrl (Get-CaPolicyUrl $p.id) -Action 'Remove the exclusion unless it is required and documented.'
        }
        if ($includedSps -and $p.state -eq 'enabled') {
            Add-Finding -Severity Info -Category 'Conditional Access' -Object "Policy: $($p.displayName)" `
                -Detail 'Workload identity policy covers the ConnectWise app(s) or all single-tenant service principals. Note: workload identity CA only applies to single-tenant apps you own, not multi-tenant vendor apps.' `
                -WhereToLook "Entra admin center > Conditional Access > Policies > $($p.displayName)" -PortalUrl (Get-CaPolicyUrl $p.id)
        }
    }
    if ($hits -eq 0) {
        Add-Finding -Severity Info -Category 'Conditional Access' -Object "$($policies.Count) policies" `
            -Detail 'No Conditional Access policy excludes a ConnectWise/SkyKick app.' `
            -WhereToLook 'Entra admin center > Conditional Access > Policies' -PortalUrl "$(Get-PortalBase)/Microsoft_AAD_ConditionalAccess/ConditionalAccessBlade/~/Policies"
    }
}

function Test-VendorPermissions {
    # Informational: what the ConnectWise apps can do, for scoping exposure
    param([hashtable]$VendorSps)
    $graphNames = @{}
    foreach ($sp in $VendorSps.Values) {
        $grants = (Get-GraphPaged "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments").Rows
        if (-not $grants) { continue }
        $perms = foreach ($g in $grants) {
            if (-not $g.resourceId) { continue }
            if (-not $graphNames.ContainsKey($g.resourceId)) {
                $res = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($g.resourceId)?`$select=displayName,appRoles" -OutputType Hashtable
                $graphNames[$g.resourceId] = $res
            }
            $res  = $graphNames[$g.resourceId]
            $role = @($res.appRoles) | Where-Object { $_.id -eq $g.appRoleId } | Select-Object -First 1
            "$($res.displayName): $(if ($role) { $role.value } else { $g.appRoleId })"
        }
        $permList = @($perms | Sort-Object -Unique)
        $riskList = @($permList | Where-Object { $HighRiskPermissions -contains (($_ -split ': ', 2)[-1]) })
        Add-Finding -Severity Info -Category 'Vendor app permissions' -Object "$($sp.displayName) ($($sp.appId))" `
            -Detail "$($permList.Count) application permissions, $($riskList.Count) high-risk: $(($riskList | ForEach-Object { ($_ -split ': ', 2)[-1] }) -join ', '). Full list in Apps.csv." `
            -WhereToLook "Entra admin center > Enterprise apps > $($sp.displayName) > Security > Permissions" `
            -PortalUrl (Get-EnterpriseAppUrl $sp.id $sp.appId 'Permissions')
    }
}

function Get-AppInventory {
    # Every third-party enterprise app, for spotting others worth removing. Read-only like everything else.
    param([hashtable]$VendorSps)

    $all = $script:AllSps
    if (-not $all) {
        $all = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id,appId,displayName,accountEnabled,appOwnerOrganizationId,servicePrincipalType,publisherName,verifiedPublisher,appRoles&$top=999' -Activity 'Enterprise apps').Rows
    }
    $byId = @{}
    foreach ($sp in $all) { if ($sp.id) { $byId[$sp.id] = $sp } }

    # Application permissions: one call per resource API instead of one per app. These five
    # cover what matters for data access; anything else shows as "other APIs" by count.
    $appPerms = @{}   # client SP id -> list of "API: permission"
    foreach ($resAppId in $PermissionResources.Keys) {
        $res = $all | Where-Object { $_.appId -eq $resAppId } | Select-Object -First 1
        if (-not $res) { continue }
        $roles = @{}
        foreach ($r in @($res.appRoles)) { if ($r.id) { $roles[[string]$r.id] = $r.value } }
        $assigned = (Get-GraphPaged "https://graph.microsoft.com/v1.0/servicePrincipals/$($res.id)/appRoleAssignedTo?`$top=999" -Activity "$($PermissionResources[$resAppId]) app permissions").Rows
        foreach ($a in $assigned) {
            if ($a.principalType -ne 'ServicePrincipal' -or -not $a.principalId) { continue }
            $name = if ($roles.ContainsKey([string]$a.appRoleId)) { $roles[[string]$a.appRoleId] } else { 'default access' }
            if (-not $appPerms.ContainsKey($a.principalId)) { $appPerms[$a.principalId] = [System.Collections.Generic.List[string]]::new() }
            $appPerms[$a.principalId].Add("$($PermissionResources[$resAppId]): $name")
        }
    }

    # Delegated permissions: admin consent (AllPrincipals) scopes, and how many users consented themselves
    $adminScopes = @{}; $userConsents = @{}; $userScopes = @{}
    $grants = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$top=999' -Activity 'Delegated permission grants').Rows
    foreach ($g in $grants) {
        if (-not $g.clientId) { continue }
        # Same API labels as the application permissions, so "Exchange Online" is not also "Office 365 Exchange Online"
        $resSp = $byId[$g.resourceId]
        $api = if ($resSp -and $PermissionResources.Contains([string]$resSp.appId)) { $PermissionResources[[string]$resSp.appId] } elseif ($resSp) { $resSp.displayName } else { 'API' }
        if ($g.consentType -eq 'AllPrincipals') {
            if (-not $adminScopes.ContainsKey($g.clientId)) { $adminScopes[$g.clientId] = [System.Collections.Generic.List[string]]::new() }
            foreach ($s in ([string]$g.scope -split '\s+' | Where-Object { $_ })) { $adminScopes[$g.clientId].Add("${api}: $s") }
        } else {
            $userConsents[$g.clientId] = 1 + [int]$userConsents[$g.clientId]
            # Risky scopes users granted themselves are the classic consent-phishing pattern
            if (-not $userScopes.ContainsKey($g.clientId)) { $userScopes[$g.clientId] = [System.Collections.Generic.List[string]]::new() }
            foreach ($s in ([string]$g.scope -split '\s+' | Where-Object { $_ })) { $userScopes[$g.clientId].Add("${api}: $s") }
        }
    }

    # Last sign-in per app (needs Entra ID P1; beta only)
    $lastSignIn = @{}; $signInNote = $null
    try {
        $acts = (Get-GraphPaged 'https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities?$top=999' -Activity 'App sign-in activity').Rows
        foreach ($a in $acts) { if ($a.appId -and $a.lastSignInActivity.lastSignInDateTime) { $lastSignIn[[string]$a.appId] = ConvertTo-UtcDate $a.lastSignInActivity.lastSignInDateTime } }
    } catch {
        $signInNote = 'unknown (needs Entra ID P1)'
    }

    $staleBefore = [datetime]::UtcNow.AddDays(-90)
    $count = 0
    foreach ($sp in $all) {
        if ($sp.servicePrincipalType -ne 'Application') { continue }   # skips managed identities and legacy entries
        if (-not $sp.appOwnerOrganizationId -or $MicrosoftOwnerTenants -contains [string]$sp.appOwnerOrganizationId) { continue }

        $perms    = if ($appPerms.ContainsKey($sp.id)) { @($appPerms[$sp.id] | Sort-Object -Unique) } else { @() }
        $scopes   = if ($adminScopes.ContainsKey($sp.id)) { @($adminScopes[$sp.id] | Sort-Object -Unique) } else { @() }
        $uScopes  = if ($userScopes.ContainsKey($sp.id)) { @($userScopes[$sp.id] | Sort-Object -Unique) } else { @() }
        $isRisky  = { $HighRiskPermissions -contains (($_ -split ': ', 2)[-1]) }
        $risky    = @(@(@($perms) + @($scopes) | Where-Object $isRisky) + @($uScopes | Where-Object $isRisky | ForEach-Object { "$_ (user consent)" }) | Sort-Object -Unique)
        $isVendor = $VendorSps.ContainsKey($sp.id)
        $owner    = if ($sp.appOwnerOrganizationId -eq $script:Tenant.Id) { 'This tenant (custom app)' } elseif ($sp.appOwnerOrganizationId -eq $VendorOwnerTenantId) { 'ConnectWise' } else { [string]$sp.appOwnerOrganizationId }
        $verified = if ($sp.verifiedPublisher.displayName) { $sp.verifiedPublisher.displayName } else { '' }

        $last = $null; $lastText = $signInNote
        if (-not $signInNote) {
            $last = $lastSignIn[[string]$sp.appId]
            $lastText = if ($last) { Format-Utc $last } else { 'No sign-in recorded' }
        }
        $stale = -not $signInNote -and (-not $last -or $last -lt $staleBefore)

        $flags = @()
        if ($isVendor)             { $flags += 'ConnectWise/SkyKick (see IOC findings)' }
        if ($risky.Count)          { $flags += 'High-risk permissions' }
        if ($stale)                { $flags += 'Unused 90+ days' }
        if (-not $verified -and $owner -ne 'This tenant (custom app)') { $flags += 'Unverified publisher' }

        $count++
        $AppInventory.Add([pscustomobject]@{
            Tenant               = $script:Tenant.Name
            TenantId             = $script:Tenant.Id
            App                  = $sp.displayName
            AppId                = $sp.appId
            Flags                = $flags -join '; '
            Enabled              = [bool]$sp.accountEnabled
            Publisher            = $(if ($sp.publisherName) { $sp.publisherName } else { '' })
            VerifiedPublisher    = $verified
            OwnerTenant          = $owner
            LastSignIn           = $lastText
            HighRiskPermissions  = $risky -join '; '
            AppPermissions       = $perms -join '; '
            AdminDelegatedScopes = $scopes -join '; '
            UserConsents         = [int]$userConsents[$sp.id]
            PortalUrl            = Get-EnterpriseAppUrl $sp.id $sp.appId 'Properties'
            ToRemove             = 'Enterprise apps > app > Properties: set Enabled for users to sign-in to No to test, then Delete. Turn off user consent (Enterprise apps > Consent and permissions) so users cannot add it back.'
        })
    }

    $mine  = @($AppInventory | Where-Object TenantId -eq $script:Tenant.Id)
    $riskN = @($mine | Where-Object HighRiskPermissions).Count
    $staleN = @($mine | Where-Object { $_.Flags -like '*Unused 90+ days*' }).Count
    Add-Finding -Severity Info -Category 'App inventory' -Object "$count third-party enterprise apps" `
        -Detail "$riskN with high-risk permissions, $(if ($signInNote) { 'last sign-in unknown (needs Entra ID P1)' } else { "$staleN unused for 90+ days" }). Full list in Apps.csv and the app inventory section of the HTML report." `
        -WhereToLook 'Entra admin center > Enterprise apps > All applications (Application type: Enterprise Applications)' `
        -PortalUrl "$(Get-PortalBase)/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview"
}

#endregion

function Invoke-Check {
    param([string]$Name, [scriptblock]$Block)
    Write-Host "  Checking $Name..."
    try { & $Block }
    catch {
        Add-Finding -Severity Review -Category 'Audit failed' -Object $Name `
            -Detail "Check could not complete: $(Get-ErrorText $_). Review this area manually." -WhereToLook 'See the matching section of the Entra admin center' -PortalUrl ''
        Write-Warning "  $Name failed: $(Get-ErrorText $_)"
    }
}

#region Report

function Write-ConsoleReport {
    param($Items)
    $colors = @{ Critical = 'Red'; High = 'Yellow'; Review = 'Cyan'; Info = 'DarkGray' }
    foreach ($f in $Items | Sort-Object { $SeverityOrder[$_.Severity] }, Category, When) {
        Write-Host ("[{0}] {1}: {2}" -f $f.Severity.ToUpper(), $f.Category, $f.Object) -ForegroundColor $colors[$f.Severity]
        Write-Host "    $($f.Detail)"
        if ($f.Severity -ne 'Info') {
            Write-Host "    Where:  $($f.WhereToLook)" -ForegroundColor Gray
            if ($f.Action) { Write-Host "    Action: $($f.Action)" -ForegroundColor Gray }
            if ($f.PortalUrl) { Write-Host "    Link:   $($f.PortalUrl)" -ForegroundColor DarkCyan }
        }
    }
}

function Export-HtmlReport {
    param($Items, $Apps, [string]$Path)
    $enc ={ param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><title>ConnectWise SkyKick IOC Audit</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fff}
h1{font-size:22px}h2{font-size:18px;margin-top:32px;border-bottom:1px solid #ccc;padding-bottom:4px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #ddd;padding:6px;vertical-align:top;text-align:left}
th{background:#f3f3f3}.Critical{background:#fde2e1}.High{background:#fff4ce}.Review{background:#e6f2fb}.Info{color:#666}
.sev{font-weight:600;white-space:nowrap}.small{color:#555;font-size:12px}
</style></head><body>
<h1>ConnectWise Cloud Backup (SkyKick) IOC audit</h1>
<p class="small">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') local. Review window from $(& $enc (Format-Utc $Since)). Read-only; nothing was changed.
Source: <a href="https://www.huntress.com/blog/vendor-credential-enables-unauthorized-access">Huntress advisory</a>. Disable ConnectWise apps, do not delete them.</p>
"@)
    foreach ($t in $Items | Group-Object TenantId) {
        $counts = ($t.Group | Group-Object Severity | Sort-Object { $SeverityOrder[$_.Name] } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        [void]$sb.Append("<h2>$(& $enc $t.Group[0].Tenant) <span class='small'>$(& $enc $t.Name) &mdash; $counts</span></h2>")
        [void]$sb.Append('<table><tr><th>Severity</th><th>Category</th><th>Object</th><th>Detail</th><th>Where to look</th><th>Action</th></tr>')
        foreach ($f in $t.Group | Sort-Object { $SeverityOrder[$_.Severity] }, Category, When) {
            $where = & $enc $f.WhereToLook
            if ($f.PortalUrl) { $where += "<br><a href='$(& $enc $f.PortalUrl)' target='_blank'>Open in portal</a>" }
            [void]$sb.Append("<tr class='$($f.Severity)'><td class='sev'>$($f.Severity)</td><td>$(& $enc $f.Category)</td><td>$(& $enc $f.Object)</td><td>$(& $enc $f.Detail)</td><td>$where</td><td>$(& $enc $f.Action)</td></tr>")
        }
        [void]$sb.Append('</table>')

        $tApps = @($Apps | Where-Object TenantId -eq $t.Name)
        if ($tApps) {
            [void]$sb.Append("<h3>Third-party app inventory ($($tApps.Count))</h3><p class='small'>Not IOC findings: every non-Microsoft enterprise app, for spotting others to remove. To remove one: open it, set <i>Enabled for users to sign-in?</i> to No to test, then Delete. Turn off user consent (Enterprise apps &gt; Consent and permissions) so users cannot add it back. Do not delete ConnectWise apps; disable them.</p>")
            [void]$sb.Append('<table><tr><th>App</th><th>Flags</th><th>Enabled</th><th>Publisher</th><th>Last sign-in</th><th>High-risk permissions</th><th>All permissions</th><th>User consents</th></tr>')
            foreach ($a in $tApps) {
                $cls  = if ($a.HighRiskPermissions) { 'Review' } else { '' }
                $pub  = if ($a.VerifiedPublisher) { "$(& $enc $a.VerifiedPublisher) (verified)" } elseif ($a.Publisher) { "$(& $enc $a.Publisher) (unverified)" } else { 'unknown' }
                $pub += "<br><span class='small'>$(& $enc $a.OwnerTenant)</span>"
                $permsAll = @()
                if ($a.AppPermissions)       { $permsAll += "<i>Application:</i> $(& $enc $a.AppPermissions)" }
                if ($a.AdminDelegatedScopes) { $permsAll += "<i>Delegated (admin consent):</i> $(& $enc $a.AdminDelegatedScopes)" }
                $permsAll = $permsAll -join '<br>'
                [void]$sb.Append("<tr class='$cls'><td><a href='$(& $enc $a.PortalUrl)' target='_blank'>$(& $enc $a.App)</a><br><span class='small'>$(& $enc $a.AppId)</span></td><td>$(& $enc $a.Flags)</td><td>$(if ($a.Enabled) { 'Yes' } else { 'No' })</td><td>$pub</td><td>$(& $enc $a.LastSignIn)</td><td>$(& $enc $a.HighRiskPermissions)</td><td class='small'>$permsAll</td><td>$($a.UserConsents)</td></tr>")
            }
            [void]$sb.Append('</table>')
        }
    }
    [void]$sb.Append('</body></html>')
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}

#endregion

#region Main

try {
    # Microsoft.Graph.Authentication provides Connect-MgGraph and Invoke-MgGraphRequest, which is all this needs
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
            Write-Host 'Installing Microsoft.Graph.Authentication...'
            Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module Microsoft.Graph.Authentication
    }

    $connectArgs = @{ NoWelcome = $true; ContextScope = 'Process' }
    if ($ClientId)      { $connectArgs.ClientId = $ClientId }
    if ($UseDeviceCode) { $connectArgs.UseDeviceCode = $true }

    # Build the tenant list
    $tenants = [System.Collections.Generic.List[object]]::new()
    switch ($PSCmdlet.ParameterSetName) {
        'List' {
            if (-not (Test-Path -LiteralPath $TenantListPath)) { throw "Tenant list not found: $TenantListPath" }
            $firstLine = Get-Content -LiteralPath $TenantListPath -TotalCount 1
            if ($firstLine -match '(^|,)"?TenantId"?(,|$)') {
                foreach ($row in Import-Csv -LiteralPath $TenantListPath) {
                    if ($row.TenantId) { $tenants.Add([pscustomobject]@{ Id = $row.TenantId.Trim(); Name = $(if ($row.Name) { $row.Name } else { $row.TenantId.Trim() }) }) }
                }
            } else {
                foreach ($line in Get-Content -LiteralPath $TenantListPath) {
                    $l = $line.Trim()
                    if ($l -and -not $l.StartsWith('#')) { $tenants.Add([pscustomobject]@{ Id = $l; Name = $l }) }
                }
            }
        }
        'Partner' {
            Write-Host 'Signing in to your partner tenant to list GDAP customers...'
            Connect-MgGraph @connectArgs -Scopes 'DelegatedAdminRelationship.Read.All' | Out-Null
            $customers = (Get-GraphPaged 'https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminCustomers').Rows
            foreach ($c in $customers) { $tenants.Add([pscustomobject]@{ Id = $c.tenantId; Name = $c.displayName }) }
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Found $($tenants.Count) GDAP customers."
        }
        default {
            if ($TenantId) { foreach ($t in $TenantId) { $tenants.Add([pscustomobject]@{ Id = $t.Trim(); Name = $t.Trim() }) } }
            else           { $tenants.Add([pscustomobject]@{ Id = $null; Name = $null }) }
        }
    }
    if ($tenants.Count -eq 0) { throw 'No tenants to audit.' }

    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $csv  = Join-Path $OutputPath 'Findings.csv'
    $html = Join-Path $OutputPath 'Report.html'
    $appsCsv = Join-Path $OutputPath 'Apps.csv'
    foreach ($f in $csv, $appsCsv) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }   # per-tenant saves append

    $i = 0
    foreach ($t in $tenants) {
        $i++
        Write-Host ''
        Write-Host ("=" * 78) -ForegroundColor DarkGray
        Write-Host "[$i/$($tenants.Count)] Connecting to $(if ($t.Name) { $t.Name } else { 'your home tenant' })..." -ForegroundColor White

        $script:Tenant = [pscustomobject]@{ Id = $t.Id; Name = $t.Name }
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $args2 = $connectArgs.Clone()
            if ($t.Id) { $args2.TenantId = $t.Id }
            Connect-MgGraph @args2 -Scopes $Scopes | Out-Null

            $ctx = Get-MgContext
            $org = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName' -OutputType Hashtable).value | Select-Object -First 1
            $script:Tenant = [pscustomobject]@{ Id = $ctx.TenantId; Name = $(if ($org.displayName) { $org.displayName } else { $t.Name }) }
            Write-Host "Connected to $($script:Tenant.Name) ($($script:Tenant.Id)) as $($ctx.Account)" -ForegroundColor Green
        } catch {
            if (-not $script:Tenant.Id) { $script:Tenant.Id = $t.Id }
            Add-Finding -Severity Review -Category 'Audit failed' -Object 'Sign-in' `
                -Detail "Could not connect: $(Get-ErrorText $_). Check GDAP roles and that Microsoft Graph Command Line Tools is consented in this tenant." `
                -WhereToLook 'Partner Center > Customers > (customer) > Admin relationships' -PortalUrl ''
            Write-Warning "Could not connect to $($t.Name): $(Get-ErrorText $_)"
            $Findings | Where-Object TenantId -eq $script:Tenant.Id | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Append
            continue
        }

        # Each check is independent so one missing permission or license does not stop the rest.
        # The audit log runs before the credential check so new secrets can be tied to who added them.
        $script:AllSps = $null
        $vendorSps  = Invoke-Check 'ConnectWise / SkyKick apps' { Test-VendorApps }
        if ($vendorSps -isnot [hashtable]) { $vendorSps = @{} }
        Invoke-Check 'Directory roles' { Test-RoleAssignments -VendorSps $vendorSps } | Out-Null
        $credActors = Invoke-Check 'Audit log' { Test-AuditLog }
        if ($credActors -isnot [hashtable]) { $credActors = @{} }
        Invoke-Check 'New secrets and certificates' { Test-NewCredentials -CredentialActors $credActors } | Out-Null
        Invoke-Check 'Sign-in logs' { Test-SignIns -VendorSps $vendorSps -VendorListKnown ($null -ne $script:AllSps) } | Out-Null
        Invoke-Check 'Conditional Access' { Test-ConditionalAccess -VendorSps $vendorSps } | Out-Null
        Invoke-Check 'Vendor app permissions' { Test-VendorPermissions -VendorSps $vendorSps } | Out-Null
        Invoke-Check 'Third-party app inventory' { Get-AppInventory -VendorSps $vendorSps } | Out-Null

        $tenantFindings = $Findings | Where-Object TenantId -eq $script:Tenant.Id
        Write-Host ''
        Write-ConsoleReport $tenantFindings
        $s = $tenantFindings | Group-Object Severity
        Write-Host ''
        Write-Host ("Summary for {0}: {1}" -f $script:Tenant.Name, (($s | Sort-Object { $SeverityOrder[$_.Name] } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')) -ForegroundColor White

        # Saved per tenant so stopping a long multi-tenant run keeps what is already done
        $tenantApps = @($AppInventory | Where-Object TenantId -eq $script:Tenant.Id | Sort-Object { -not $_.HighRiskPermissions }, App)
        $riskyApps  = @($tenantApps | Where-Object HighRiskPermissions)
        if ($riskyApps) {
            Write-Host ''
            Write-Host "Third-party apps with high-risk permissions (full inventory in Apps.csv):" -ForegroundColor White
            foreach ($a in $riskyApps) {
                Write-Host ("  {0} [{1}] - {2}" -f $a.App, $(if ($a.Enabled) { 'enabled' } else { 'disabled' }), $a.HighRiskPermissions) -ForegroundColor Cyan
                Write-Host ("    Last sign-in: {0}. Publisher: {1}. {2}" -f $a.LastSignIn, $(if ($a.VerifiedPublisher) { "$($a.VerifiedPublisher) (verified)" } elseif ($a.Publisher) { "$($a.Publisher) (unverified)" } else { 'unknown' }), $a.PortalUrl) -ForegroundColor Gray
            }
        }

        # Saved per tenant so stopping a long multi-tenant run keeps what is already done
        $tenantFindings | Sort-Object { $SeverityOrder[$_.Severity] }, Category, When |
            Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Append
        if ($tenantApps) { $tenantApps | Export-Csv -LiteralPath $appsCsv -NoTypeInformation -Encoding UTF8 -Append }
        Write-Host "Saved to $OutputPath" -ForegroundColor DarkGray
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

    # Rewrite the CSV sorted across all tenants, and build the HTML
    $sorted = $Findings | Sort-Object Tenant, { $SeverityOrder[$_.Severity] }, Category, When
    $sorted | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $sortedApps = $AppInventory | Sort-Object Tenant, { -not $_.HighRiskPermissions }, App
    if ($sortedApps) { $sortedApps | Export-Csv -LiteralPath $appsCsv -NoTypeInformation -Encoding UTF8 }
    Export-HtmlReport -Items $sorted -Apps $sortedApps -Path $html

    Write-Host ''
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host 'Tenants with Critical or High findings:' -ForegroundColor White
    $flagged = $Findings | Where-Object { $_.Severity -in 'Critical', 'High' } | Group-Object Tenant
    if ($flagged) {
        foreach ($g in $flagged) {
            $c = @($g.Group | Where-Object Severity -eq 'Critical').Count
            $h = @($g.Group | Where-Object Severity -eq 'High').Count
            Write-Host ("  {0}: {1} Critical, {2} High" -f $g.Name, $c, $h) -ForegroundColor $(if ($c) { 'Red' } else { 'Yellow' })
        }
    } else { Write-Host '  None' -ForegroundColor Green }
    Write-Host ''
    Write-Host "Findings: $csv"
    if ($sortedApps) { Write-Host "Apps:     $appsCsv" }
    Write-Host "Report:   $html"
    exit 0
} catch {
    Write-Error "Audit failed: $(Get-ErrorText $_)"
    exit 1
}

#endregion
