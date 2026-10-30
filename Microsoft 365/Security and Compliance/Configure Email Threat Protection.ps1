<#
.SYNOPSIS
    Audits a Microsoft 365 tenant's spam, phishing and malware filtering against
    Microsoft's recommended Standard or Strict settings, and optionally applies them.
    Works with Exchange Online Protection alone or with Defender for Office 365
    (included in Microsoft 365 Business Premium).

.DESCRIPTION
    Built for onboarding: run it first to see what a customer already has, then run
    it again with -Apply to bring the tenant up to the baseline. Without -Apply,
    NOTHING IS CHANGED; the audit lists every change -Apply would make.

    What it checks (and what -Apply fixes):

      Threat policies (anti-spam, anti-malware, anti-phishing, outbound spam, and with
      Defender: Safe Links, Safe Attachments, Teams ZAP, Safe Attachments for
      SharePoint/OneDrive/Teams). Every default and custom policy is compared with
      Microsoft's Standard or Strict values. A setting that is already stricter than
      the target passes, so -Apply never loosens anything.
        -Apply updates the default policies. Custom policies are reported but only
        changed with -IncludeCustomPolicies. Policies managed by Microsoft (Standard,
        Strict and Built-in protection presets) are never modified.
        With Defender, -Apply also creates a "<PolicyName> Safe Links" policy for all
        accepted domains when recipients would otherwise only get Built-in protection,
        whose Safe Links settings are below Standard (no URL rewriting, click-through
        allowed, internal mail not scanned).
      Preset security policies: which are on and who they cover. Microsoft recommends
        them because Microsoft keeps their settings current, but they can only be
        created by turning them on once in the Defender portal. -EnablePresetPolicy
        turns on an existing preset for all accepted domains.
      Impersonation protection (Defender): the users and domains protected.
        -ProtectedUsers / -ProtectedDomains add them to the default anti-phishing policy.
      Automatic external forwarding (outbound spam policy). -Apply sets it Off unless a
        mailbox forwards externally, which it lists; -ForceForwardingOff overrides.
      Connection filter: the IP allow list (reported) and the safe list (-Apply turns off).
      Allow entries that bypass filtering: allowed sender domains, IP allow list,
        SCL -1 mail flow rules, Tenant Allow/Block List allows, phishing simulation
        overrides. These are REPORTED ONLY and never removed, because they are often
        deliberate (phishing simulations, line-of-business senders).
      Mail routing: MX records per domain, third-party filters in front of Microsoft
        365, and Enhanced Filtering for Connectors (reported only).
      Email authentication: SPF, DKIM and DMARC per domain. -Apply creates DKIM keys
        and enables DKIM where the CNAME records are published; SPF and DMARC live in
        public DNS, so the exact records to publish are reported instead.
      External sender tag in Outlook. -Apply turns it on.
      Organization customization: -Apply runs Enable-OrganizationCustomization first
        in tenants that need it.

    Every finding cites its source. Primary: Microsoft Learn "Recommendations for
    Microsoft 365 security settings" (updated 2026-08-10). Secondary: CISA SCuBA
    Exchange Online and Security Suite baselines, and the CIS Microsoft 365
    Foundations Benchmark. See $Sources below for the links.

    Output: console summary, Findings.csv, Changes.csv, Report.html, and a JSON
    snapshot of every policy as it was before any change (for documentation and
    rollback) in -OutputPath.

    Permissions: Exchange Administrator or Security Administrator to apply; Global
    Reader or Security Reader is enough to audit. For a customer through GDAP, sign
    in with your partner account and pass -DelegatedOrganization.

.PARAMETER DelegatedOrganization
    One or more customer tenant domains (contoso.onmicrosoft.com) to run against with
    your partner (GDAP) sign-in. Omit to run against the tenant you sign in to.

.PARAMETER Level
    Standard (default) or Strict. Strict quarantines spam and bulk mail instead of
    moving it to Junk, uses lower bulk and sending thresholds, and a more aggressive
    phishing threshold. Microsoft suggests Standard for most users and Strict for
    high-value targets.

.PARAMETER Apply
    Make the changes listed by the audit. You are asked to confirm per tenant unless
    -Force is also given.

.PARAMETER Force
    With -Apply, skip the per-tenant confirmation prompt.

.PARAMETER IncludeCustomPolicies
    With -Apply, also bring enabled custom policies up to the baseline. By default only
    the default policies are changed and custom policies are reported.

.PARAMETER EnablePresetPolicy
    With -Apply, turn on the Standard or Strict (per -Level) preset security policy for
    all accepted domains. The preset must have been turned on once in the Defender
    portal; if it never was, the script says so instead.

.PARAMETER ProtectedUsers
    Defender only. Senders to protect from impersonation (executives, finance), as
    "Display Name;address@domain" or just the address. Added to the default
    anti-phishing policy; existing entries are kept. Up to 350.

.PARAMETER ProtectedDomains
    Defender only. Partner or supplier domains (not your own) to protect from
    impersonation. Your accepted domains are protected automatically.

.PARAMETER ForceForwardingOff
    With -Apply, turn automatic external forwarding off even when mailboxes are set to
    forward externally. Those forwards stop working (senders get NDR 5.7.520).

.PARAMETER PolicyName
    Prefix for policies this script creates. Default "Baseline" (e.g. "Baseline Safe Links").

.PARAMETER DefenderLicense
    Auto (default) detects Defender for Office 365 from the cmdlets available in the
    tenant. Yes or No overrides the detection.

.PARAMETER DnsServer
    DNS server for the SPF, DKIM, DMARC and MX lookups. Default: this computer's resolver.

.PARAMETER OutputPath
    Folder for the reports. Default C:\temp\Email Threat Protection <timestamp>.

.PARAMETER UserPrincipalName
    Account to sign in with (pre-fills the sign-in prompt).

.EXAMPLE
    & '.\Configure Email Threat Protection.ps1'
    Audits the tenant you sign in to against the Standard baseline. Changes nothing.

.EXAMPLE
    & '.\Configure Email Threat Protection.ps1' -DelegatedOrganization contoso.onmicrosoft.com -Apply -ProtectedUsers 'Jane Doe;jane@contoso.com', 'cfo@contoso.com'
    Onboards a customer through GDAP: applies the Standard baseline and protects two
    executives from impersonation.

.EXAMPLE
    & '.\Configure Email Threat Protection.ps1' -Level Strict -Apply -EnablePresetPolicy
    Applies Strict values to the default policies and turns on the Strict preset policy.

.NOTES
    Name:    Configure Email Threat Protection
    Author:  Brad Brown, Systems Administrator
    Context: Technician workstation (interactive), PowerShell 5.1 or 7+ on Windows
    Module:  ExchangeOnlineManagement 3.x (installed if missing). DNS checks use
             Resolve-DnsName (Windows) and are skipped where it is not available.
#>

[CmdletBinding()]
param(
    [string[]]$DelegatedOrganization,

    [ValidateSet('Standard', 'Strict')]
    [string]$Level = 'Standard',

    [switch]$Apply,

    [switch]$Force,

    [switch]$IncludeCustomPolicies,

    [switch]$EnablePresetPolicy,

    [ValidateCount(0, 350)]
    [string[]]$ProtectedUsers,

    [string[]]$ProtectedDomains,

    [switch]$ForceForwardingOff,

    [ValidatePattern('^[\w .-]+$')]
    [string]$PolicyName = 'Baseline',

    [ValidateSet('Auto', 'Yes', 'No')]
    [string]$DefenderLicense = 'Auto',

    [string]$DnsServer,

    [string]$OutputPath = "C:\temp\Email Threat Protection $(Get-Date -Format 'yyyy-MM-dd HHmm')",

    [string]$UserPrincipalName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region Sources

$Sources = [ordered]@{
    'MS-REC'    = 'https://learn.microsoft.com/en-us/defender-office-365/recommended-settings-for-eop-and-office365'
    'MS-PRESET' = 'https://learn.microsoft.com/en-us/defender-office-365/preset-security-policies'
    'MS-FWD'    = 'https://learn.microsoft.com/en-us/defender-office-365/outbound-spam-policies-external-email-forwarding'
    'MS-CONN'   = 'https://learn.microsoft.com/en-us/defender-office-365/connection-filter-policies-configure'
    'MS-EF'     = 'https://learn.microsoft.com/en-us/exchange/mail-flow-best-practices/use-connectors-to-configure-mail-flow/enhanced-filtering-for-connectors'
    'MS-SPF'    = 'https://learn.microsoft.com/en-us/defender-office-365/email-authentication-spf-configure'
    'MS-DKIM'   = 'https://learn.microsoft.com/en-us/defender-office-365/email-authentication-dkim-configure'
    'MS-DMARC'  = 'https://learn.microsoft.com/en-us/defender-office-365/email-authentication-dmarc-configure'
    'MS-ORG'    = 'https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/enable-organizationcustomization'
    'MS-ADV'    = 'https://learn.microsoft.com/en-us/defender-office-365/advanced-delivery-policy-configure'
    'MS-EXT'    = 'https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-externalinoutlook'
    'CISA-EXO'  = 'https://github.com/cisagov/ScubaGear/blob/main/PowerShell/ScubaGear/baselines/exo.md'
    'CISA-SS'   = 'https://github.com/cisagov/ScubaGear/blob/main/PowerShell/ScubaGear/baselines/securitysuite.md'
    'CIS'       = 'https://www.cisecurity.org/benchmark/microsoft_365'
}
$SourceNames = @{
    'MS-REC'    = 'Microsoft: Recommendations for Microsoft 365 security settings'
    'MS-PRESET' = 'Microsoft: Preset security policies'
    'MS-FWD'    = 'Microsoft: Control external email forwarding'
    'MS-CONN'   = 'Microsoft: Configure the default connection filter policy'
    'MS-EF'     = 'Microsoft: Enhanced filtering for connectors'
    'MS-SPF'    = 'Microsoft: Set up SPF'
    'MS-DKIM'   = 'Microsoft: Set up DKIM'
    'MS-DMARC'  = 'Microsoft: Set up DMARC'
    'MS-ORG'    = 'Microsoft: Enable-OrganizationCustomization'
    'MS-ADV'    = 'Microsoft: Advanced delivery for phishing simulations'
    'MS-EXT'    = 'Microsoft: Set-ExternalInOutlook'
    'CISA-EXO'  = 'CISA SCuBA Exchange Online baseline'
    'CISA-SS'   = 'CISA SCuBA Security Suite baseline'
    'CIS'       = 'CIS Microsoft 365 Foundations Benchmark v6.0.1'
}

#endregion

#region Baseline (values from MS-REC unless the source says otherwise)

function New-Setting {
    # Type: Exact | Min (higher is stricter) | Max (lower is stricter, 0 = service default) |
    #       Rank (action strength) | Tag (quarantine policy) | Empty (list must be empty)
    param(
        [string]$Name, [string]$Label, $Standard, $Strict,
        [string]$Type = 'Exact', [string]$Severity = 'Medium',
        [switch]$Mdo, [switch]$NoFix, [string]$Source = 'MS-REC',
        [hashtable]$Rank, [string]$OnMismatch, [string]$Note
    )
    [pscustomobject]@{
        Name = $Name; Label = $Label; Standard = $Standard; Strict = $Strict; Type = $Type; Severity = $Severity
        Mdo = [bool]$Mdo; NoFix = [bool]$NoFix; Source = $Source; Rank = $Rank; OnMismatch = $OnMismatch; Note = $Note
    }
}

$FullAccess  = 'DefaultFullAccessPolicy'
$FullNotify  = 'DefaultFullAccessWithNotificationPolicy'
$AdminOnly   = 'AdminOnlyAccessPolicy'

$MalwareSettings = @(
    New-Setting EnableFileFilter 'Common attachments filter' $true $true -Severity High -Note 'CISA MS.SECURITYSUITE.1.1v1 requires blocking click-to-run attachments.'
    New-Setting FileTypeAction 'Common attachments filter action' 'Reject' 'Reject' -Severity Low
    New-Setting ZapEnabled 'Zero-hour auto purge (ZAP) for malware' $true $true -Severity High
    New-Setting QuarantineTag 'Malware quarantine policy' $AdminOnly $AdminOnly -Type Tag -Severity Low
)

$SpamSettings = @(
    New-Setting BulkThreshold 'Bulk email threshold (BCL)' 6 5 -Type Max
    New-Setting MarkAsSpamBulkMail 'Mark bulk email as spam' 'On' 'On'
    New-Setting SpamAction 'Spam action' 'MoveToJmf' 'Quarantine' -Type Rank
    New-Setting SpamQuarantineTag 'Spam quarantine policy' $FullAccess $FullNotify -Type Tag -Severity Low
    New-Setting HighConfidenceSpamAction 'High confidence spam action' 'Quarantine' 'Quarantine' -Type Rank -Severity High
    New-Setting HighConfidenceSpamQuarantineTag 'High confidence spam quarantine policy' $FullNotify $FullNotify -Type Tag -Severity Low
    New-Setting PhishSpamAction 'Phishing action' 'Quarantine' 'Quarantine' -Type Rank -Severity High -Note 'CISA MS.SECURITYSUITE.6.1v1: spam and phishing SHALL NOT be delivered to the inbox.'
    New-Setting PhishQuarantineTag 'Phishing quarantine policy' $FullNotify $FullNotify -Type Tag -Severity Low
    New-Setting HighConfidencePhishAction 'High confidence phishing action' 'Quarantine' 'Quarantine' -Type Rank -Severity High
    New-Setting HighConfidencePhishQuarantineTag 'High confidence phishing quarantine policy' $AdminOnly $AdminOnly -Type Tag -Severity Low
    New-Setting BulkSpamAction 'Bulk email action' 'MoveToJmf' 'Quarantine' -Type Rank
    New-Setting BulkQuarantineTag 'Bulk quarantine policy' $FullAccess $FullNotify -Type Tag -Severity Low
    New-Setting QuarantineRetentionPeriod 'Days to keep spam in quarantine' 30 30 -Type Min -Severity Low
    New-Setting InlineSafetyTipsEnabled 'Spam safety tips' $true $true -Severity Low
    New-Setting PhishZapEnabled 'ZAP for phishing' $true $true -Severity High
    New-Setting SpamZapEnabled 'ZAP for spam' $true $true
    New-Setting AllowedSenderDomains 'Allowed sender domains' $null $null -Type Empty -Severity High -NoFix `
        -Note 'Microsoft: adding domains to the allowed domains list is a bad idea; attackers can send mail that would otherwise be filtered. Use the Tenant Allow/Block List or Advanced delivery instead. CIS 2.1.14 and CISA MS.SECURITYSUITE.6.2v1 agree. Not removed automatically.'
    New-Setting AllowedSenders 'Allowed senders' $null $null -Type Empty -NoFix `
        -Note 'Allowed senders skip spam filtering and are easy to spoof. Use the Tenant Allow/Block List instead. Not removed automatically.'
)
# Advanced Spam Filter options: Microsoft recommends all Off (they cause false positives). Reported, never changed.
$SpamSettings += @(foreach ($asf in 'IncreaseScoreWithImageLinks', 'IncreaseScoreWithNumericIps', 'IncreaseScoreWithRedirectToOtherPort',
                                   'IncreaseScoreWithBizOrInfoUrls', 'MarkAsSpamEmptyMessages', 'MarkAsSpamEmbedTagsInHtml',
                                   'MarkAsSpamJavaScriptInHtml', 'MarkAsSpamFormTagsInHtml', 'MarkAsSpamFramesInHtml',
                                   'MarkAsSpamWebBugsInHtml', 'MarkAsSpamObjectTagsInHtml', 'MarkAsSpamSensitiveWordList',
                                   'MarkAsSpamSpfRecordHardFail', 'MarkAsSpamFromAddressAuthFail', 'MarkAsSpamNdrBackscatter') {
    New-Setting $asf "Advanced Spam Filter: $asf" 'Off' 'Off' -Severity Low -NoFix -OnMismatch Review `
        -Note 'Microsoft recommends Off: ASF options tend to cause false positives. Left as is; turn off in the policy if users report good mail as spam.'
})

$PhishSettings = @(
    New-Setting EnableSpoofIntelligence 'Spoof intelligence' $true $true -Severity High
    New-Setting HonorDmarcPolicy 'Honor sender DMARC policy' $true $true -Severity High
    New-Setting DmarcQuarantineAction 'Action for DMARC p=quarantine' 'Quarantine' 'Quarantine' -Type Rank
    New-Setting DmarcRejectAction 'Action for DMARC p=reject' 'Reject' 'Reject' -Type Rank -Rank @{ Quarantine = 1; Reject = 2 }
    New-Setting AuthenticationFailAction 'Spoof action' 'MoveToJmf' 'Quarantine' -Type Rank
    New-Setting SpoofQuarantineTag 'Spoof quarantine policy' $FullAccess $FullNotify -Type Tag -Severity Low
    New-Setting EnableFirstContactSafetyTips 'First contact safety tip' $true $true -Severity Low -Note 'CISA MS.SECURITYSUITE.2.4v1: user safety tips SHOULD be displayed.'
    New-Setting EnableUnauthenticatedSender 'Unauthenticated sender (?) indicator' $true $true -Severity Low
    New-Setting EnableViaTag 'Show "via" tag' $true $true -Severity Low
    New-Setting PhishThresholdLevel 'Phishing email threshold' 3 4 -Type Min -Mdo
    New-Setting EnableOrganizationDomainsProtection 'Impersonation: protect domains I own' $true $true -Mdo -Note 'CISA MS.SECURITYSUITE.2.2v1.'
    New-Setting EnableMailboxIntelligence 'Mailbox intelligence' $true $true -Mdo
    New-Setting EnableMailboxIntelligenceProtection 'Mailbox intelligence impersonation protection' $true $true -Mdo
    New-Setting TargetedUserProtectionAction 'User impersonation action' 'Quarantine' 'Quarantine' -Type Rank -Mdo
    New-Setting TargetedUserQuarantineTag 'User impersonation quarantine policy' $FullNotify $FullNotify -Type Tag -Severity Low -Mdo
    New-Setting TargetedDomainProtectionAction 'Domain impersonation action' 'Quarantine' 'Quarantine' -Type Rank -Mdo
    New-Setting TargetedDomainQuarantineTag 'Domain impersonation quarantine policy' $FullNotify $FullNotify -Type Tag -Severity Low -Mdo
    New-Setting MailboxIntelligenceProtectionAction 'Mailbox intelligence impersonation action' 'MoveToJmf' 'Quarantine' -Type Rank -Mdo
    New-Setting MailboxIntelligenceQuarantineTag 'Mailbox intelligence quarantine policy' $FullAccess $FullNotify -Type Tag -Severity Low -Mdo
    New-Setting EnableSimilarUsersSafetyTips 'User impersonation safety tip' $true $true -Severity Low -Mdo
    New-Setting EnableSimilarDomainsSafetyTips 'Domain impersonation safety tip' $true $true -Severity Low -Mdo
    New-Setting EnableUnusualCharactersSafetyTips 'Unusual characters safety tip' $true $true -Severity Low -Mdo
)

$OutboundSettings = @(
    New-Setting RecipientLimitExternalPerHour 'External recipients per hour' 500 400 -Type Max -Note '0 means the service default (10,000), which lets a compromised account send far more spam before it is stopped.'
    New-Setting RecipientLimitInternalPerHour 'Internal recipients per hour' 1000 800 -Type Max -Severity Low
    New-Setting RecipientLimitPerDay 'Recipients per day' 1000 800 -Type Max
    New-Setting ActionWhenThresholdReached 'Action when a limit is reached' 'BlockUser' 'BlockUser' -Type Rank -Rank @{ Alert = 0; BlockUserForToday = 1; BlockUser = 2 }
)

$SafeLinksSettings = @(
    New-Setting EnableSafeLinksForEmail 'Safe Links for email' $true $true -Severity High -Mdo
    New-Setting EnableForInternalSenders 'Apply to internal email' $true $true -Mdo
    New-Setting ScanUrls 'Real-time URL scanning' $true $true -Mdo -Note 'CISA MS.SECURITYSUITE.7.2v1.'
    New-Setting DeliverMessageAfterScan 'Wait for scan before delivery' $true $true -Mdo
    New-Setting DisableUrlRewrite 'Do not rewrite URLs' $false $false -Mdo
    New-Setting EnableSafeLinksForTeams 'Safe Links for Teams' $true $true -Mdo -Note 'CISA MS.SECURITYSUITE.7.1v1.'
    New-Setting EnableSafeLinksForOffice 'Safe Links for Office apps' $true $true -Mdo
    New-Setting TrackClicks 'Track user clicks' $true $true -Severity Low -Mdo -Note 'CISA MS.SECURITYSUITE.7.3v1.'
    New-Setting AllowClickThrough 'Let users click through to the original URL' $false $false -Mdo
)

$SafeAttachmentSettings = @(
    New-Setting Enable 'Safe Attachments enabled' $true $true -Severity High -Mdo
    New-Setting Action 'Unknown malware response' 'Block' 'Block' -Severity High -Mdo
    New-Setting QuarantineTag 'Safe Attachments quarantine policy' $AdminOnly $AdminOnly -Type Tag -Severity Low -Mdo
    New-Setting Redirect 'Redirect detected attachments' $false $false -Severity Low -Mdo
)

$AtpGlobalSettings = @(
    New-Setting EnableATPForSPOTeamsODB 'Safe Attachments for SharePoint, OneDrive and Teams' $true $true -Severity High -Mdo -Note 'Recommended value from the Built-in protection column. CISA MS.SECURITYSUITE.1.4v1.'
)

$TeamsSettings = @(
    New-Setting ZapEnabled 'ZAP for Teams messages' $true $true -Mdo
)

$ConnectionSettings = @(
    New-Setting EnableSafeList 'Connection filter safe list' $false $false -Source CIS `
        -Note 'CIS 2.1.13: the safe list is a Microsoft-maintained allow list you cannot see; mail from it skips spam filtering.'
    New-Setting IPAllowList 'Connection filter IP allow list' $null $null -Type Empty -NoFix -Source CIS `
        -Note 'CIS 2.1.12 and CISA MS.SECURITYSUITE.8.1v1: IP allow lists SHOULD NOT be used; listed IPs skip spam filtering. Use Advanced delivery for phishing simulations. Not removed automatically.'
)

# Policy types. PresetGroup says which preset rule shadows the default policy: EOP, ATP, Both or none.
$PolicyTypes = @(
    @{ Area = 'Anti-malware';     Get = 'Get-MalwareFilterPolicy';          Set = 'Set-MalwareFilterPolicy';          RuleGet = 'Get-MalwareFilterRule';          RuleProp = 'MalwareFilterPolicy';          Settings = $MalwareSettings;        Mdo = $false; PresetGroup = 'EOP';  Portal = 'https://security.microsoft.com/antimalwarev2' }
    @{ Area = 'Anti-spam';        Get = 'Get-HostedContentFilterPolicy';    Set = 'Set-HostedContentFilterPolicy';    RuleGet = 'Get-HostedContentFilterRule';    RuleProp = 'HostedContentFilterPolicy';    Settings = $SpamSettings;           Mdo = $false; PresetGroup = 'EOP';  Portal = 'https://security.microsoft.com/antispam' }
    @{ Area = 'Anti-phishing';    Get = 'Get-AntiPhishPolicy';              Set = 'Set-AntiPhishPolicy';              RuleGet = 'Get-AntiPhishRule';              RuleProp = 'AntiPhishPolicy';              Settings = $PhishSettings;          Mdo = $false; PresetGroup = 'Both'; Portal = 'https://security.microsoft.com/antiphishing' }
    @{ Area = 'Outbound spam';    Get = 'Get-HostedOutboundSpamFilterPolicy'; Set = 'Set-HostedOutboundSpamFilterPolicy'; RuleGet = 'Get-HostedOutboundSpamFilterRule'; RuleProp = 'HostedOutboundSpamFilterPolicy'; Settings = $OutboundSettings;    Mdo = $false; PresetGroup = $null;  Portal = 'https://security.microsoft.com/antispam' }
    @{ Area = 'Safe Links';       Get = 'Get-SafeLinksPolicy';              Set = 'Set-SafeLinksPolicy';              RuleGet = 'Get-SafeLinksRule';              RuleProp = 'SafeLinksPolicy';              Settings = $SafeLinksSettings;      Mdo = $true;  PresetGroup = 'ATP';  Portal = 'https://security.microsoft.com/safelinksv2' }
    @{ Area = 'Safe Attachments'; Get = 'Get-SafeAttachmentPolicy';         Set = 'Set-SafeAttachmentPolicy';         RuleGet = 'Get-SafeAttachmentRule';         RuleProp = 'SafeAttachmentPolicy';         Settings = $SafeAttachmentSettings; Mdo = $true;  PresetGroup = 'ATP';  Portal = 'https://security.microsoft.com/safeattachmentv2' }
)

# Action strength: a higher rank is stricter
$ActionRank = @{ NoAction = 0; AddXHeader = 0; ModifySubject = 0; BccMessage = 0; MoveToJmf = 1; Redirect = 1; Quarantine = 2; Delete = 2 }

# Quarantine policies that give the same or more than the recommended one. NotificationEnabledPolicy is what some
# organizations have in place of DefaultFullAccessPolicy (MS-REC footnote 1); it also turns notifications on.
$TagEquivalents = @{
    $FullAccess = @($FullAccess, $FullNotify, 'NotificationEnabledPolicy')
    $FullNotify = @($FullNotify, 'NotificationEnabledPolicy')
    $AdminOnly  = @($AdminOnly)
}
$BuiltInTags = @($FullAccess, $FullNotify, $AdminOnly, 'NotificationEnabledPolicy')

# MX host patterns for common filtering services in front of Microsoft 365
$MxVendors = [ordered]@{
    'arsmtp\.com|appriver'                 = 'AppRiver / Zix'
    'pphosted\.com|ppe-hosted\.com'        = 'Proofpoint'
    'mimecast'                             = 'Mimecast'
    'barracudanetworks\.com|barracuda'     = 'Barracuda'
    'sophos'                               = 'Sophos'
    'iphmx\.com'                           = 'Cisco Secure Email'
    'messagelabs|symanteccloud'            = 'Broadcom Email Security.cloud'
    'mailcontrol\.com'                     = 'Forcepoint'
    'antispamcloud\.com|spamexperts'       = 'N-able Mail Assure / SpamExperts'
    'mailprotector'                        = 'Mailprotector'
    'spamtitan|titanhq'                    = 'SpamTitan'
    'hornetsecurity|hornetdrive'           = 'Hornetsecurity'
    'trendmicro|tmes\.'                    = 'Trend Micro'
    'inkyphishfence|inky\.com'             = 'INKY'
    'vadesecure|vade\.'                    = 'Vade'
    'google\.com|googlemail\.com'          = 'Google Workspace'
    'secureserver\.net'                    = 'GoDaddy'
    'emailsrvr\.com'                       = 'Rackspace'
}
$MicrosoftMx = '\.mail\.protection\.outlook\.com\.?$|\.mx\.microsoft\.?$'

#endregion

#region Findings and changes

$Findings = [System.Collections.Generic.List[object]]::new()
$Changes  = [System.Collections.Generic.List[object]]::new()
$SeverityOrder = @{ High = 0; Medium = 1; Low = 2; '' = 3 }
$ResultOrder   = @{ 'Fix failed' = 0; Fail = 1; Review = 2; Fixed = 3; Info = 4; Pass = 5 }

function Format-Value {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value) | ForEach-Object { [string]$_ }) -join ', ' }
    [string]$Value
}

function Add-Finding {
    param(
        [string]$Area, [string]$Object, [string]$Setting, $Current, $Expected,
        [ValidateSet('Pass', 'Fail', 'Review', 'Info')][string]$Result,
        [string]$Severity = '', [string]$Note, [string]$Source, [string]$Portal, [switch]$PassThru
    )
    $f = [pscustomobject]@{
        Tenant    = $script:Tenant.Name
        Area      = $Area
        Object    = $Object
        Setting   = $Setting
        Current   = Format-Value $Current
        Expected  = Format-Value $Expected
        Result    = $Result
        Severity  = $(if ($Result -in 'Fail', 'Review') { $Severity } else { '' })
        Fix       = ''
        ChangeId  = ''
        Note      = $Note
        Source    = $(if ($Source) { $SourceNames[$Source] } else { '' })
        SourceUrl = $(if ($Source) { $Sources[$Source] } else { '' })
        Portal    = $Portal
    }
    $Findings.Add($f)
    if ($PassThru) { $f }
}

function Format-Argument {
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return (@($Value) | ForEach-Object { Format-Argument $_ }) -join ',' }
    "'" + ([string]$Value -replace "'", "''") + "'"
}

function Add-Change {
    # Steps: one or more @{ Cmdlet = 'Set-X'; Params = [ordered]@{...} }, run in order when -Apply is given.
    # Findings: the findings this change fixes, so their result can be updated after it runs.
    param([string]$Target, [string]$Description, [object[]]$Steps, [object[]]$Findings, [string]$After, [string]$Domain)
    $id = 'C{0:d3}' -f ($Changes.Count + 1)
    $cmd = ($Steps | ForEach-Object {
        $s = $_
        (@($s.Cmdlet) + @($s.Params.Keys | ForEach-Object { "-$_ $(Format-Argument $s.Params[$_])" })) -join ' '
    }) -join '; '
    $Changes.Add([pscustomobject]@{
        Tenant = $script:Tenant.Name; Id = $id; Target = $Target; Description = $Description
        Command = $cmd; Status = 'Planned'; Error = ''; Steps = $Steps; After = $After; Domain = $Domain
    })
    foreach ($f in @($Findings | Where-Object { $_ })) { $f.ChangeId = $id; $f.Fix = 'Auto (-Apply)' }
}

function Get-ErrorText {
    param($ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $msg = $ErrorRecord.ErrorDetails.Message }
    ($msg -replace '\s+', ' ').Trim()
}

#endregion

#region Comparison

function Compare-Setting {
    param($Rule, $Actual, $Expected)
    switch ($Rule.Type) {
        'Min'   { if ($null -ne $Actual -and "$Actual" -ne '' -and [double]$Actual -ge [double]$Expected) { 'Pass' } else { 'Fail' } }
        'Max'   { $a = if ("$Actual" -eq '') { 0 } else { [double]$Actual }; if ($a -gt 0 -and $a -le [double]$Expected) { 'Pass' } else { 'Fail' } }
        'Rank'  {
            $ranks = if ($Rule.Rank) { $Rule.Rank } else { $ActionRank }
            $ra = $ranks[[string]$Actual]
            if ($null -eq $ra) { 'Review' } elseif ($ra -ge $ranks[[string]$Expected]) { 'Pass' } else { 'Fail' }
        }
        'Tag'   {
            $ok = $TagEquivalents[[string]$Expected]
            if (-not $ok) { $ok = @($Expected) }
            if ($ok -contains [string]$Actual) { 'Pass' }
            elseif ("$Actual" -eq '' -or $BuiltInTags -contains [string]$Actual) { 'Fail' }
            else { 'Review' }   # a custom quarantine policy someone chose on purpose
        }
        'Empty' { if (@($Actual | Where-Object { "$_" -ne '' }).Count -eq 0) { 'Pass' } else { 'Fail' } }
        default { if ((Format-Value $Actual) -eq (Format-Value $Expected)) { 'Pass' } else { 'Fail' } }
    }
}

function Compare-Policy {
    # Compares one policy with a settings list. Returns a plan (parameters to set and the findings they fix)
    # so extra checks can add to it before Register-PolicyChange turns it into one Set-* call.
    param($Policy, [hashtable]$Def, [bool]$CanFix, [string]$Scope)
    $plan = @{ Params = [ordered]@{}; Findings = [System.Collections.Generic.List[object]]::new(); Scope = $Scope }
    foreach ($s in $Def.Settings) {
        if ($s.Mdo -and -not $script:Mdo) { continue }
        $expected = $s.$Level
        $actual   = $Policy.($s.Name)
        $result   = Compare-Setting $s $actual $expected
        if ($result -eq 'Fail' -and $s.OnMismatch) { $result = $s.OnMismatch }

        $note = $s.Note
        if ($s.Type -eq 'Empty' -and $result -ne 'Pass') {
            $overlap = @(@($actual) | Where-Object { $script:PhishSimValues -contains ([string]$_).ToLower() })
            if ($overlap) { $note = "$note $($overlap.Count) of these entries are also in the phishing simulation override (Advanced delivery), so they are redundant here." }
        }
        if ($result -eq 'Fail' -and -not $CanFix -and -not $s.NoFix) {
            $note = "$note Custom policy, not changed (use -IncludeCustomPolicies). It applies to: $Scope".Trim()
        }
        $f = Add-Finding -Area $Def.Area -Object $Policy.Name -Setting $s.Label -Current $actual -Expected $(if ($s.Type -eq 'Empty') { '(empty)' } else { $expected }) `
            -Result $result -Severity $s.Severity -Note $note -Source $s.Source -Portal $Def.Portal -PassThru
        if ($result -eq 'Fail') {
            if ($CanFix -and -not $s.NoFix) { $plan.Params[$s.Name] = $expected; $plan.Findings.Add($f) }
            else { $f.Fix = 'Manual' }
        }
    }
    $plan
}

function Register-PolicyChange {
    param($Policy, [hashtable]$Def, [hashtable]$Plan, [switch]$NoIdentity)
    if ($Plan.Params.Count -eq 0) { return }
    $params = [ordered]@{}
    if (-not $NoIdentity) { $params.Identity = [string]$Policy.Name }
    foreach ($k in $Plan.Params.Keys) { $params[$k] = $Plan.Params[$k] }
    Add-Change -Target "$($Def.Area): $($Policy.Name)" -Description "Set $($Plan.Params.Count) setting(s) to the $Level baseline" `
        -Steps @(@{ Cmdlet = $Def.Set; Params = $params }) -Findings $Plan.Findings
}

function Get-PolicyKind {
    param($Policy)
    $rpt = [string]$Policy.RecommendedPolicyType
    if ($Policy.Name -eq "$PolicyName Safe Links") { return 'Baseline' }
    if ($rpt -eq 'Strict' -or $Policy.Name -like 'Strict Preset Security Policy*') { return 'Strict preset' }
    if ($rpt -eq 'Standard' -or $Policy.Name -like 'Standard Preset Security Policy*') { return 'Standard preset' }
    if ($rpt -match 'BuiltIn' -or $Policy.IsBuiltInProtection -or $Policy.Name -like 'Built-In Protection Policy*') { return 'Built-in protection' }
    if ($Policy.IsDefault) { return 'Default' }
    'Custom'
}

$ScopeProps = 'SentTo', 'SentToMemberOf', 'RecipientDomainIs', 'From', 'FromMemberOf', 'SenderDomainIs'

function Get-RuleScope {
    param($Rule)
    $parts = foreach ($p in $ScopeProps) {
        $v = @($Rule.$p | Where-Object { $_ })
        if ($v) { "$p $($v -join ', ')" }
        $x = @($Rule."ExceptIf$p" | Where-Object { $_ })
        if ($x) { "except $p $($x -join ', ')" }
    }
    if ($parts) { $parts -join '; ' } else { 'all recipients' }
}

function Test-RuleCoversAll {
    # True when an enabled rule has no exceptions and either no conditions or every accepted domain
    param($Rule)
    if (-not $Rule -or [string]$Rule.State -ne 'Enabled') { return $false }
    foreach ($p in $ScopeProps) { if (@($Rule."ExceptIf$p" | Where-Object { $_ }).Count) { return $false } }
    foreach ($p in 'SentTo', 'SentToMemberOf', 'From', 'FromMemberOf') { if (@($Rule.$p | Where-Object { $_ }).Count) { return $false } }
    $domains = @($Rule.RecipientDomainIs | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() })
    if (-not $domains) { return $true }
    foreach ($d in $script:MailDomains) { if ($domains -notcontains $d) { return $false } }
    $true
}

function Test-PresetCoversAll {
    param([string]$Group)
    if ($Group -eq 'Both') { return (Test-PresetCoversAll 'EOP') -and (-not $script:Mdo -or (Test-PresetCoversAll 'ATP')) }
    foreach ($lvl in 'Strict', 'Standard') { if (Test-RuleCoversAll $script:Presets["$Group$lvl"]) { return "$lvl preset" } }
    $false
}

#endregion

#region DNS

function Get-DnsRecord {
    param([string]$Name, [ValidateSet('TXT', 'MX', 'CNAME')][string]$Type)
    $a = @{ Name = $Name; Type = $Type; DnsOnly = $true; ErrorAction = 'Stop' }
    if ($DnsServer) { $a.Server = $DnsServer }
    try { @(Resolve-DnsName @a | Where-Object { [string]$_.Type -eq $Type }) }
    catch {
        if ($_.Exception.Message -match 'does not exist|No records|not found|9003|9501') { return }
        throw
    }
}

function Get-TxtRecord {
    param([string]$Name, [string]$Pattern)
    @(Get-DnsRecord $Name TXT | ForEach-Object { ($_.Strings -join '').Trim() } | Where-Object { $_ -match $Pattern })
}

function Get-SpfInfo {
    # Counts DNS lookups the way receivers do (include, a, mx, ptr, exists, redirect; nested includes too)
    param([string]$Domain, [int]$Depth = 0)
    $info = [pscustomobject]@{ Lookups = 0; Includes = [System.Collections.Generic.List[string]]::new(); Error = $null }
    if ($Depth -gt 10) { return $info }
    $rec = Get-TxtRecord $Domain '^v=spf1(\s|$)' | Select-Object -First 1
    if (-not $rec) { if ($Depth -gt 0) { $info.Error = "$Domain (included) has no SPF record" }; return $info }
    foreach ($term in ($rec -split '\s+')) {
        $t = $term.TrimStart('+', '-', '~', '?')
        if ($t -match '^(include:|redirect=)(.+)$') {
            $target = $Matches[2].ToLower()
            $info.Lookups++
            $info.Includes.Add($target)
            $sub = Get-SpfInfo -Domain $target -Depth ($Depth + 1)
            $info.Lookups += $sub.Lookups
            foreach ($i in $sub.Includes) { $info.Includes.Add($i) }
            if ($sub.Error -and -not $info.Error) { $info.Error = $sub.Error }
        } elseif ($t -match '^(a|mx|ptr)([:/].*)?$' -or $t -match '^exists:') {
            $info.Lookups++
        }
    }
    $info
}

#endregion

#region Checks

function Initialize-TenantContext {
    $org = Get-OrganizationConfig
    $script:Snapshot.OrganizationConfig = $org | Select-Object Name, DisplayName, IsDehydrated
    $accepted = @(Get-AcceptedDomain)
    $script:Snapshot.AcceptedDomains = $accepted | Select-Object DomainName, DomainType, Default
    $script:AllDomains  = @($accepted | ForEach-Object { ([string]$_.DomainName).ToLower() })
    # Hybrid routing domains (tenant.mail.onmicrosoft.com) never receive internet mail directly
    $script:MailDomains = @($script:AllDomains | Where-Object { $_ -notlike '*.mail.onmicrosoft.com' })
    $script:InitialDomain = $script:AllDomains | Where-Object { $_ -match '^[^.]+\.onmicrosoft\.com$' } | Select-Object -First 1
    $script:CustomDomains = @($script:MailDomains | Where-Object { $_ -notlike '*.onmicrosoft.com' })

    # Defender for Office 365: its cmdlets are only offered in tenants that have it
    $script:Mdo = switch ($DefenderLicense) {
        'Yes'   { $true }
        'No'    { $false }
        default {
            if (-not (Get-Command Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue)) { $false }
            else { try { $null = Get-SafeAttachmentPolicy -ErrorAction Stop; $true } catch { $false } }
        }
    }
    $lic = if ($script:Mdo) { 'Defender for Office 365 detected (Plan 1 or 2; included in Business Premium and E5)' }
           else { 'Exchange Online Protection only. Safe Links, Safe Attachments and impersonation protection need Defender for Office 365 (included in Business Premium). Override with -DefenderLicense Yes if this is wrong.' }
    Add-Finding -Area 'Tenant' -Object $script:Tenant.Name -Setting 'Email security license' -Current $(if ($script:Mdo) { 'Defender for Office 365' } else { 'EOP only' }) -Result Info -Note $lic

    if ($org.IsDehydrated) {
        $f = Add-Finding -Area 'Tenant' -Object $script:Tenant.Name -Setting 'Organization customization' -Current 'Not enabled' -Expected 'Enabled' -Result Fail -Severity Medium -Source 'MS-ORG' -PassThru `
            -Note 'Required before policies can be changed. If later changes fail saying customization is not enabled, wait (up to 24 hours) and run again.'
        Add-Change -Target 'Tenant' -Description 'Enable organization customization' -Steps @(@{ Cmdlet = 'Enable-OrganizationCustomization'; Params = [ordered]@{} }) -Findings $f
    }

    # Primary addresses show which domains actually send mail; the rest are treated as parked
    try {
        $recipients = @(Get-EXORecipient -ResultSize Unlimited -PropertySets Minimum)
        $script:SendingDomains = @($recipients | ForEach-Object { ([string]$_.PrimarySmtpAddress -split '@')[-1].ToLower() } | Sort-Object -Unique)
        $note = "$($recipients.Count) recipients. Domains used as a primary address: $(($script:SendingDomains | Where-Object { $script:AllDomains -contains $_ }) -join ', ')."
    } catch {
        $script:SendingDomains = $script:CustomDomains   # assume every domain sends, the safer reading
        $note = "Could not list recipients ($(Get-ErrorText $_)), so every custom domain is treated as sending mail."
    }
    Add-Finding -Area 'Tenant' -Object $script:Tenant.Name -Setting 'Accepted domains' -Current ($script:AllDomains -join ', ') -Result Info -Note $note
}

function Test-Forwarding {
    # Mailboxes that forward outside the organization; turning automatic forwarding off would break these
    $boxes = @(Get-EXOMailbox -ResultSize Unlimited -Filter 'ForwardingSmtpAddress -ne $null' -Properties ForwardingSmtpAddress, PrimarySmtpAddress)
    $script:ExternalForwards = @($boxes | Where-Object {
        $addr = ([string]$_.ForwardingSmtpAddress) -replace '^smtp:', ''
        $script:AllDomains -notcontains ($addr -split '@')[-1].ToLower()
    } | ForEach-Object { '{0} -> {1}' -f $_.PrimarySmtpAddress, (([string]$_.ForwardingSmtpAddress) -replace '^smtp:', '') })
    $script:Snapshot.ExternalForwards = $script:ExternalForwards

    if ($script:ExternalForwards) {
        Add-Finding -Area 'Forwarding' -Object 'Mailboxes' -Setting 'Mailboxes forwarding outside the organization' -Current "$($script:ExternalForwards.Count)" -Result Review -Severity Medium -Source 'MS-FWD' `
            -Note ("Confirm each is wanted: " + (($script:ExternalForwards | Select-Object -First 15) -join '; ') + $(if ($script:ExternalForwards.Count -gt 15) { '; ...' })) `
            -Portal 'https://admin.exchange.microsoft.com/#/mailboxes'
    } else {
        Add-Finding -Area 'Forwarding' -Object 'Mailboxes' -Setting 'Mailboxes forwarding outside the organization' -Current '0' -Result Pass -Source 'MS-FWD'
    }
    Add-Finding -Area 'Forwarding' -Object 'Inbox rules' -Setting 'Inbox rules that forward externally' -Result Info `
        -Note 'Not checked here (it needs every mailbox). Run "Get Mailbox Rules and Forwards.ps1" or the Auto forwarded messages report before turning forwarding off.'

    $rd = Get-RemoteDomain -Identity Default
    Add-Finding -Area 'Forwarding' -Object 'Remote domain: Default' -Setting 'Allow automatic forwarding' -Current $rd.AutoForwardEnabled -Result Info -Source 'MS-FWD' `
        -Note 'Informational: the outbound spam policy is the control Microsoft documents. When either one blocks forwarding, the block wins.'
}

function Test-PresetPolicies {
    $script:Presets = @{}
    $eop = @(Get-EOPProtectionPolicyRule -ErrorAction SilentlyContinue)
    $atp = if ($script:Mdo) { @(Get-ATPProtectionPolicyRule -ErrorAction SilentlyContinue) } else { @() }
    foreach ($lvl in 'Standard', 'Strict') {
        $script:Presets["EOP$lvl"] = $eop | Where-Object { $_.Name -eq "$lvl Preset Security Policy" } | Select-Object -First 1
        $script:Presets["ATP$lvl"] = $atp | Where-Object { $_.Name -eq "$lvl Preset Security Policy" } | Select-Object -First 1
    }
    $script:Snapshot.PresetRules = @($eop) + @($atp)

    $anyOn = $false
    foreach ($lvl in 'Strict', 'Standard') {
        foreach ($grp in @('EOP') + @(if ($script:Mdo) { 'ATP' })) {
            $r = $script:Presets["$grp$lvl"]
            $what = if ($grp -eq 'EOP') { 'anti-spam, anti-malware, anti-phishing' } else { 'Safe Links, Safe Attachments, impersonation' }
            if (-not $r) {
                Add-Finding -Area 'Preset policies' -Object "$lvl preset ($what)" -Setting 'State' -Current 'Never turned on' -Result Info -Source 'MS-PRESET'
            } else {
                if ([string]$r.State -eq 'Enabled') { $anyOn = $true }
                Add-Finding -Area 'Preset policies' -Object "$lvl preset ($what)" -Setting 'State' -Current "$($r.State); applies to: $(Get-RuleScope $r)" -Result Info -Source 'MS-PRESET'
            }
        }
    }

    $portal = 'https://security.microsoft.com/presetSecurityPolicies'
    $eopRule = $script:Presets["EOP$Level"]
    $atpRule = $script:Presets["ATP$Level"]
    if ($EnablePresetPolicy) {
        if (-not $eopRule -or ($script:Mdo -and -not $atpRule)) {
            Add-Finding -Area 'Preset policies' -Object "$Level preset" -Setting 'Turn on for all recipients' -Current 'Never turned on' -Expected 'On' -Result Fail -Severity Low -Source 'MS-PRESET' -Portal $portal `
                -Note "Microsoft: the preset's policies can only be created by turning it on in the Defender portal the first time. Turn on $Level protection there once (any recipients), then run this again with -EnablePresetPolicy."
        } else {
            $steps = @()
            foreach ($pair in @(@('EOP', $eopRule), @('ATP', $atpRule))) {
                $grp, $r = $pair
                if (-not $r) { continue }
                if (-not (Test-RuleCoversAll $r) -or [string]$r.State -ne 'Enabled') {
                    $steps += @{ Cmdlet = "Set-$($grp)ProtectionPolicyRule"; Params = [ordered]@{
                        Identity = $r.Name; RecipientDomainIs = $script:MailDomains; SentTo = $null; SentToMemberOf = $null
                        ExceptIfRecipientDomainIs = $null; ExceptIfSentTo = $null; ExceptIfSentToMemberOf = $null } }
                    if ([string]$r.State -ne 'Enabled') { $steps += @{ Cmdlet = "Enable-$($grp)ProtectionPolicyRule"; Params = [ordered]@{ Identity = $r.Name } } }
                }
            }
            if ($steps) {
                $f = Add-Finding -Area 'Preset policies' -Object "$Level preset" -Setting 'Turn on for all recipients' -Current "$($eopRule.State); $(Get-RuleScope $eopRule)" -Expected 'On for all accepted domains' -Result Fail -Severity Low -Source 'MS-PRESET' -Portal $portal -PassThru `
                    -Note 'Impersonation protection for specific users and partner domains in a preset is set in the portal (Preset security policies > Manage protection settings).'
                Add-Change -Target "Preset policies: $Level" -Description "Turn on the $Level preset for all accepted domains" -Steps $steps -Findings $f
            } else {
                Add-Finding -Area 'Preset policies' -Object "$Level preset" -Setting 'Turn on for all recipients' -Current 'On for all recipients' -Result Pass -Source 'MS-PRESET'
            }
        }
    } elseif (-not $anyOn) {
        Add-Finding -Area 'Preset policies' -Object 'Standard / Strict presets' -Setting 'In use' -Current 'Off' -Result Review -Severity Low -Source 'MS-PRESET' -Portal $portal `
            -Note 'Microsoft recommends preset security policies because Microsoft keeps their settings current; CISA MS.SECURITYSUITE accepts either the presets or equivalent settings. This script applies the same values to the default policies instead. To use a preset, turn it on once in the portal, then run with -EnablePresetPolicy.'
    }

    if ($script:Mdo) {
        $bi = Get-ATPBuiltInProtectionRule -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:Snapshot.BuiltInProtectionRule = $bi
        if ($bi) {
            $ex = @(foreach ($p in 'ExceptIfSentTo', 'ExceptIfSentToMemberOf', 'ExceptIfRecipientDomainIs') { @($bi.$p | Where-Object { $_ }) })
            if ($ex) {
                Add-Finding -Area 'Preset policies' -Object 'Built-in protection' -Setting 'Exceptions' -Current ($ex -join ', ') -Expected '(none)' -Result Review -Severity Low -Source 'MS-PRESET' -Portal $portal `
                    -Note 'Microsoft does not recommend exceptions to Built-in protection unless those users lack Defender licenses; excluded users get no Safe Links or Safe Attachments unless another policy covers them.'
            }
        }
    }
}

function Test-PolicyType {
    param([hashtable]$Def)
    if ($Def.Mdo -and -not $script:Mdo) { return }
    $policies = @(& $Def.Get)
    $script:Snapshot[$Def.Area] = $policies
    $rules = @{}
    foreach ($r in @(& $Def.RuleGet)) { $rules[[string]$r.($Def.RuleProp)] = $r }
    $script:Snapshot["$($Def.Area) rules"] = @($rules.Values)

    $shadow = if ($Def.PresetGroup) { Test-PresetCoversAll $Def.PresetGroup } else { $false }
    $order  = [System.Collections.Generic.List[string]]::new()
    if ($Def.PresetGroup) {
        foreach ($lvl in 'Strict', 'Standard') {
            $grp = if ($Def.PresetGroup -eq 'Both') { 'EOP' } else { $Def.PresetGroup }
            $r = $script:Presets["$grp$lvl"]
            if ($r -and [string]$r.State -eq 'Enabled') { $order.Add("$lvl preset ($(Get-RuleScope $r))") }
        }
    }

    $sorted = $policies | Sort-Object { $r = $rules[[string]$_.Name]; if ($r) { [int]$r.Priority } else { [int]::MaxValue } }
    foreach ($p in $sorted) {
        $kind = Get-PolicyKind $p
        if ($kind -like '*preset' -or $kind -eq 'Built-in protection') {
            if ($kind -eq 'Built-in protection') { $order.Add('Built-in protection (everyone else)') }
            Add-Finding -Area $Def.Area -Object $p.Name -Setting 'Policy type' -Current $kind -Result Info -Source 'MS-PRESET' `
                -Note 'Managed by Microsoft; settings are not compared or changed.'
            continue
        }

        if ($kind -eq 'Default') {
            $order.Add($(if ($shadow) { 'Default (not reached)' } else { 'Default (everyone else)' }))
            if ($shadow) {
                Add-Finding -Area $Def.Area -Object $p.Name -Setting 'Policy type' -Current 'Default' -Result Info -Source 'MS-PRESET' `
                    -Note "Not in effect: the $shadow covers every recipient and takes precedence. Settings not compared."
                continue
            }
            $plan = Compare-Policy -Policy $p -Def $Def -CanFix $true -Scope 'everyone not covered by a preset or custom policy'
        } else {
            $rule = $rules[[string]$p.Name]
            if (-not $rule -or [string]$rule.State -ne 'Enabled') {
                Add-Finding -Area $Def.Area -Object $p.Name -Setting 'Policy type' -Current "$kind (rule $(if ($rule) { 'disabled' } else { 'missing' }))" -Result Info `
                    -Note 'Not in effect for anyone, so settings are not compared.'
                continue
            }
            $scope = "priority $($rule.Priority): $(Get-RuleScope $rule)"
            $order.Add("'$($p.Name)' ($scope)")
            $plan = Compare-Policy -Policy $p -Def $Def -CanFix ($kind -eq 'Baseline' -or [bool]$IncludeCustomPolicies) -Scope $scope
            if ($kind -eq 'Baseline' -and (Format-Value $rule.RecipientDomainIs) -ne ($script:MailDomains -join ', ')) {
                Add-Change -Target "$($Def.Area): $($p.Name)" -Description 'Update the baseline rule to cover all accepted domains' `
                    -Steps @(@{ Cmdlet = 'Set-SafeLinksRule'; Params = [ordered]@{ Identity = $rule.Name; RecipientDomainIs = $script:MailDomains } })
            }
        }

        if ($Def.Area -eq 'Anti-phishing' -and $script:Mdo) { Test-Impersonation -Policy $p -Plan $plan -CanFix ($kind -eq 'Default' -or [bool]$IncludeCustomPolicies) }
        if ($Def.Area -eq 'Outbound spam') { Test-ForwardingMode -Policy $p -Plan $plan -Kind $kind }
        Register-PolicyChange -Policy $p -Def $Def -Plan $plan
    }

    Add-Finding -Area $Def.Area -Object 'Policy order' -Setting 'Which policy applies, first match wins' -Current ($order -join '  >  ') -Result Info -Source 'MS-PRESET'
}

function Test-Impersonation {
    param($Policy, [hashtable]$Plan, [bool]$CanFix)
    $portal = 'https://security.microsoft.com/antiphishing'

    # Users: "Display Name;address". Existing entries are kept; new ones matched on address.
    $current = @($Policy.TargetedUsersToProtect | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $have    = @($current | ForEach-Object { ($_ -split ';')[-1].Trim().ToLower() })
    $add     = @($ProtectedUsers | Where-Object { $_ } | ForEach-Object {
        $entry = if ($_ -match ';') { $_.Trim() } else { "$($_.Trim());$($_.Trim())" }
        if ($have -notcontains ($entry -split ';')[-1].Trim().ToLower()) { $entry }
    })
    if ($add -or ($current -and -not $Policy.EnableTargetedUserProtection)) {
        $f = Add-Finding -Area 'Anti-phishing' -Object $Policy.Name -Setting 'User impersonation protection' -Current "$([bool]$Policy.EnableTargetedUserProtection); $($current.Count) user(s)" `
            -Expected "True; $($current.Count + $add.Count) user(s)" -Result Fail -Severity Medium -Source 'CISA-SS' -Portal $portal -PassThru `
            -Note $(if ($add) { "Adds: $($add -join ', ')" } else { 'Users are listed but protection is off.' })
        if ($CanFix) {
            $Plan.Params.EnableTargetedUserProtection = $true
            $Plan.Params.TargetedUsersToProtect = @($current + $add)
            $Plan.Findings.Add($f)
        } else { $f.Fix = 'Manual' }
    } elseif ($current) {
        Add-Finding -Area 'Anti-phishing' -Object $Policy.Name -Setting 'User impersonation protection' -Current "$($current.Count) user(s)" -Result Pass -Source 'CISA-SS' `
            -Note ($current -join ', ')
    } else {
        Add-Finding -Area 'Anti-phishing' -Object $Policy.Name -Setting 'User impersonation protection' -Current 'No users' -Expected 'Executives and finance staff' -Result Review -Severity Medium -Source 'CISA-SS' -Portal $portal `
            -Note "CISA MS.SECURITYSUITE.2.1v1 and Microsoft recommend protecting senders in key roles (CEO, CFO, finance). Re-run with -ProtectedUsers 'Name;address', ..."
    }

    $currentD = @($Policy.TargetedDomainsToProtect | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() })
    $addD     = @($ProtectedDomains | Where-Object { $_ -and $currentD -notcontains $_.Trim().ToLower() } | ForEach-Object { $_.Trim().ToLower() })
    if ($addD -or ($currentD -and -not $Policy.EnableTargetedDomainsProtection)) {
        $f = Add-Finding -Area 'Anti-phishing' -Object $Policy.Name -Setting 'Partner domain impersonation protection' -Current "$([bool]$Policy.EnableTargetedDomainsProtection); $($currentD -join ', ')" `
            -Expected "True; $((@($currentD) + @($addD)) -join ', ')" -Result Fail -Severity Low -Source 'CISA-SS' -Portal $portal -PassThru
        if ($CanFix) {
            $Plan.Params.EnableTargetedDomainsProtection = $true
            $Plan.Params.TargetedDomainsToProtect = @($currentD + $addD)
            $Plan.Findings.Add($f)
        } else { $f.Fix = 'Manual' }
    } elseif (-not $currentD) {
        Add-Finding -Area 'Anti-phishing' -Object $Policy.Name -Setting 'Partner domain impersonation protection' -Current 'None' -Result Info -Source 'CISA-SS' `
            -Note 'Optional: CISA MS.SECURITYSUITE.2.3v1 suggests adding key suppliers and partners (-ProtectedDomains). Your own domains are covered by "protect domains I own".'
    }
}

function Test-ForwardingMode {
    param($Policy, [hashtable]$Plan, [string]$Kind)
    $mode = [string]$Policy.AutoForwardingMode
    $setting = 'Automatic external forwarding'
    if ($mode -eq 'Off') {
        Add-Finding -Area 'Outbound spam' -Object $Policy.Name -Setting $setting -Current $mode -Expected 'Off' -Result Pass -Source 'MS-REC'
        return
    }
    if ($Kind -ne 'Default' -and $mode -eq 'On') {
        Add-Finding -Area 'Outbound spam' -Object $Policy.Name -Setting $setting -Current $mode -Expected 'Off, except for approved users' -Result Review -Severity Low -Source 'MS-FWD' `
            -Note "A custom policy that allows forwarding is how Microsoft suggests exempting specific users. Confirm these should forward: $($Plan.Scope)"
        return
    }
    $note = if ($mode -eq 'Automatic') { 'Automatic behaves as On in some older tenants and Off in others; Microsoft recommends setting Off explicitly. CISA MS.EXO.1.1v2: automatic forwarding to external domains SHALL be disabled.' }
            else { 'Any user, or an attacker in a compromised mailbox, can forward mail outside the organization. CISA MS.EXO.1.1v2 requires this off.' }
    $f = Add-Finding -Area 'Outbound spam' -Object $Policy.Name -Setting $setting -Current $mode -Expected 'Off' -Result Fail -Severity $(if ($mode -eq 'On') { 'High' } else { 'Medium' }) `
        -Source 'MS-REC' -Note $note -Portal 'https://security.microsoft.com/antispam' -PassThru
    if ($Kind -ne 'Default' -and -not $IncludeCustomPolicies) { $f.Fix = 'Manual'; return }
    if ($script:ExternalForwards -and -not $ForceForwardingOff) {
        $f.Fix = 'Manual'
        $f.Note += " NOT changed: $($script:ExternalForwards.Count) mailbox(es) forward externally and would stop working (see Forwarding). Remove those forwards, or create a custom outbound policy allowing those users, then run again; or use -ForceForwardingOff."
        return
    }
    $Plan.Params.AutoForwardingMode = 'Off'
    $Plan.Findings.Add($f)
}

function Test-SafeLinksBaseline {
    # Recipients outside every preset and custom policy get Built-in protection, whose Safe Links settings are below
    # Standard. A catch-all custom policy at the lowest priority fixes that without overriding existing policies.
    if (-not $script:Mdo) { return }
    $name = "$PolicyName Safe Links"
    if (@($script:Snapshot['Safe Links'] | Where-Object { $_.Name -eq $name }).Count) { return }   # compared in Test-PolicyType

    $covered = Test-PresetCoversAll 'ATP'
    if (-not $covered) {
        $full = @($script:Snapshot['Safe Links rules'] | Where-Object { Test-RuleCoversAll $_ }) | Select-Object -First 1
        if ($full) { $covered = "custom policy '$($full.SafeLinksPolicy)'" }
    }
    $setting = 'Safe Links for recipients not in another policy'
    if ($covered) {
        Add-Finding -Area 'Safe Links' -Object 'Coverage' -Setting $setting -Current "All recipients covered by the $covered" -Result Pass -Source 'MS-PRESET'
        return
    }
    $policyParams = [ordered]@{ Name = $name }
    foreach ($s in $SafeLinksSettings) { $policyParams[$s.Name] = $s.$Level }
    $f = Add-Finding -Area 'Safe Links' -Object 'Coverage' -Setting $setting -Current 'Built-in protection only' -Expected "Custom policy at $Level values" -Result Fail -Severity Medium -Source 'MS-PRESET' `
        -Portal 'https://security.microsoft.com/safelinksv2' -PassThru `
        -Note "Built-in protection does not rewrite URLs, allows click-through and skips internal mail. -Apply creates '$name' for all accepted domains at the lowest priority, so existing policies still win for their users."
    Add-Change -Target "Safe Links: $name" -Description 'Create a Safe Links policy at baseline values for all accepted domains' -Findings $f -Steps @(
        @{ Cmdlet = 'New-SafeLinksPolicy'; Params = $policyParams }
        @{ Cmdlet = 'New-SafeLinksRule'; Params = [ordered]@{ Name = $name; SafeLinksPolicy = $name; RecipientDomainIs = $script:MailDomains } }
    )
}

function Test-DefenderGlobal {
    if (-not $script:Mdo) { return }
    $atp = Get-AtpPolicyForO365
    $script:Snapshot.AtpPolicyForO365 = $atp
    $def = @{ Area = 'Safe Attachments (global)'; Set = 'Set-AtpPolicyForO365'; Settings = $AtpGlobalSettings; Portal = 'https://security.microsoft.com/safeattachmentv2' }
    $plan = Compare-Policy -Policy $atp -Def $def -CanFix $true -Scope 'tenant-wide'
    Register-PolicyChange -Policy $atp -Def $def -Plan $plan
    Add-Finding -Area 'Safe Attachments (global)' -Object $atp.Name -Setting 'Block downloading infected files in SharePoint/OneDrive' -Result Info -Source 'MS-REC' `
        -Note 'Recommended, but set in SharePoint Online PowerShell (Set-SPOTenant -DisallowInfectedFileDownload $true), not checked here.'

    $teams = @(Get-TeamsProtectionPolicy -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($teams) {
        $script:Snapshot.TeamsProtectionPolicy = $teams
        $def = @{ Area = 'Teams protection'; Set = 'Set-TeamsProtectionPolicy'; Settings = $TeamsSettings; Portal = 'https://security.microsoft.com/threatpolicy' }
        $plan = Compare-Policy -Policy $teams -Def $def -CanFix $true -Scope 'tenant-wide'
        Register-PolicyChange -Policy $teams -Def $def -Plan $plan
    }
}

function Test-ConnectionFilter {
    $cf = Get-HostedConnectionFilterPolicy -Identity Default
    $script:Snapshot.ConnectionFilter = $cf
    $def = @{ Area = 'Connection filter'; Set = 'Set-HostedConnectionFilterPolicy'; Settings = $ConnectionSettings; Portal = 'https://security.microsoft.com/antispam' }
    $plan = Compare-Policy -Policy $cf -Def $def -CanFix $true -Scope 'all inbound mail'
    Register-PolicyChange -Policy $cf -Def $def -Plan $plan
    if (@($cf.IPBlockList | Where-Object { $_ }).Count) {
        Add-Finding -Area 'Connection filter' -Object $cf.Name -Setting 'IP block list' -Current $cf.IPBlockList -Result Info
    }
}

function Test-AllowLists {
    $script:PhishSimValues = @()
    try {
        $sim = @(Get-ExoPhishSimOverrideRule -ErrorAction Stop)
        $script:Snapshot.PhishSimOverride = $sim
        foreach ($r in $sim) {
            $script:PhishSimValues += @($r.Domains) + @($r.SenderIpRanges) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() }
            Add-Finding -Area 'Allow lists' -Object $r.Name -Setting 'Phishing simulation override (Advanced delivery)' -Current "Domains: $(Format-Value $r.Domains); IPs: $(Format-Value $r.SenderIpRanges)" -Result Info -Source 'MS-ADV' `
                -Note 'This is the supported way to deliver third-party phishing simulations. Allow-list entries elsewhere for the same senders are redundant.'
        }
    } catch {
        Add-Finding -Area 'Allow lists' -Object 'Phishing simulation override' -Setting 'Advanced delivery' -Result Info -Note "Could not read: $(Get-ErrorText $_)"
    }

    $portal = 'https://security.microsoft.com/tenantAllowBlockList'
    foreach ($type in 'Sender', 'Url', 'FileHash') {
        try {
            $items = @(Get-TenantAllowBlockListItems -ListType $type -Allow -ErrorAction Stop)
            $script:Snapshot["TABL $type allows"] = $items
            if ($items) {
                $vals = @($items | ForEach-Object { '{0} (expires {1})' -f $_.Value, $(if ($_.ExpirationDate) { ([datetime]$_.ExpirationDate).ToString('yyyy-MM-dd') } else { 'never' }) })
                Add-Finding -Area 'Allow lists' -Object 'Tenant Allow/Block List' -Setting "$type allow entries" -Current "$($items.Count)" -Result Review -Severity Low -Portal $portal `
                    -Note ("Confirm each is still needed: " + (($vals | Select-Object -First 15) -join '; ') + $(if ($vals.Count -gt 15) { '; ...' }))
            } else {
                Add-Finding -Area 'Allow lists' -Object 'Tenant Allow/Block List' -Setting "$type allow entries" -Current '0' -Result Pass
            }
        } catch {
            Add-Finding -Area 'Allow lists' -Object 'Tenant Allow/Block List' -Setting "$type allow entries" -Result Info -Note "Could not read: $(Get-ErrorText $_)"
        }
    }
    try {
        $spoof = @(Get-TenantAllowBlockListSpoofItems -ErrorAction Stop | Where-Object { [string]$_.Action -eq 'Allow' })
        if ($spoof) {
            Add-Finding -Area 'Allow lists' -Object 'Tenant Allow/Block List' -Setting 'Allowed spoofed senders' -Current "$($spoof.Count)" -Result Info -Portal $portal `
                -Note ((@($spoof | ForEach-Object { "$($_.SpoofedUser) via $($_.SendingInfrastructure)" }) | Select-Object -First 15) -join '; ')
        }
    } catch { Write-Verbose "Spoof allow list not readable: $(Get-ErrorText $_)" }
}

function Test-TransportRules {
    $rules = @(Get-TransportRule)
    $script:Snapshot.TransportRules = $rules
    $portal = 'https://admin.exchange.microsoft.com/#/transportrules'
    $hits = 0
    foreach ($r in $rules | Where-Object { [string]$_.State -eq 'Enabled' }) {
        $byIp     = @($r.SenderIpRanges | Where-Object { $_ }).Count -gt 0
        $bySender = @(foreach ($p in 'SenderDomainIs', 'From', 'FromAddressContainsWords', 'FromAddressMatchesPatterns') { @($r.$p | Where-Object { $_ }) }).Count -gt 0
        $cond = @(foreach ($p in 'SenderIpRanges', 'SenderDomainIs', 'From', 'FromAddressContainsWords', 'FromAddressMatchesPatterns', 'HeaderContainsMessageHeader') {
            $v = @($r.$p | Where-Object { $_ }); if ($v) { "$p $($v -join ', ')" } }) -join '; '

        if ([string]$r.SetSCL -eq '-1') {
            $hits++
            if ($byIp) {
                Add-Finding -Area 'Mail flow rules' -Object $r.Name -Setting 'Bypasses spam filtering (SCL -1)' -Current $cond -Result Review -Severity Medium -Source 'MS-EF' -Portal $portal `
                    -Note 'Limited to sender IPs. If this is for a filtering service in front of Microsoft 365, Microsoft says to disable SCL -1 rules once Enhanced Filtering for Connectors is on. If it is for a phishing simulation, use Advanced delivery instead.'
            } else {
                Add-Finding -Area 'Mail flow rules' -Object $r.Name -Setting 'Bypasses spam filtering (SCL -1)' -Current $(if ($cond) { $cond } else { 'no sender condition' }) -Result Fail -Severity High -Source 'CIS' -Portal $portal `
                    -Note $(if ($bySender) { 'Matches on sender address or domain only, which attackers can spoof. CIS: mail flow rules should not allow-list domains. Restrict it to the sender IPs, or replace it with Tenant Allow/Block List entries.' }
                            else { 'Bypasses filtering without a sender IP condition. Confirm it is needed and narrow it to sender IPs.' })
            }
        }
        $hdr = [string]$r.SetHeaderName
        if ($hdr -match 'SkipSafeLinksProcessing|SkipSafeAttachmentProcessing') {
            $hits++
            Add-Finding -Area 'Mail flow rules' -Object $r.Name -Setting "Sets $hdr" -Current $(if ($cond) { $cond } else { 'no sender condition' }) -Result Review -Severity $(if ($byIp) { 'Low' } else { 'Medium' }) -Portal $portal `
                -Note 'Turns off Safe Links or Safe Attachments for matching mail. Usually for phishing simulations; make sure it is limited to the vendor IPs.'
        }
        $outside = @(foreach ($p in 'RedirectMessageTo', 'BlindCopyTo', 'AddToRecipients', 'CopyTo') {
            @($r.$p | Where-Object { $_ -and $script:AllDomains -notcontains ([string]$_ -split '@')[-1].ToLower() })
        })
        if ($outside) {
            $hits++
            Add-Finding -Area 'Mail flow rules' -Object $r.Name -Setting 'Sends copies outside the organization' -Current ($outside -join ', ') -Result Review -Severity Medium -Source 'CISA-EXO' -Portal $portal `
                -Note 'Mail flow rules are a form of forwarding; confirm this is intended (journaling, archiving, a vendor).'
        }
    }
    if ($hits -eq 0) {
        Add-Finding -Area 'Mail flow rules' -Object "$(@($rules).Count) rules" -Setting 'Rules that bypass filtering or copy mail out' -Current 'None' -Result Pass -Source 'CIS'
    }
}

function Test-MailRouting {
    $script:DomainMx = @{}
    if (-not $script:DnsAvailable) { return }
    $thirdParty = @()
    foreach ($d in $script:CustomDomains) {
        $mx = @(Get-DnsRecord $d MX | Sort-Object Preference | ForEach-Object { ([string]$_.NameExchange).TrimEnd('.').ToLower() })
        $kind = if (-not $mx) { 'None' } elseif (@($mx | Where-Object { $_ -notmatch $MicrosoftMx }).Count -eq 0) { 'Microsoft' } else { 'Third-party' }
        $vendor = ''
        if ($kind -eq 'Third-party') {
            foreach ($pat in $MxVendors.Keys) { if (($mx -join ' ') -match $pat) { $vendor = $MxVendors[$pat]; break } }
            if (-not $vendor) { $vendor = 'unrecognized service' }
            $thirdParty += "$d ($vendor)"
        }
        $script:DomainMx[$d] = $kind
        Add-Finding -Area 'Mail routing' -Object $d -Setting 'MX' -Current ($mx -join ', ') -Result Info `
            -Note $(switch ($kind) { 'Microsoft' { 'Points to Microsoft 365.' } 'None' { 'No MX record; the domain cannot receive internet mail.' } default { "Mail passes through $vendor before Microsoft 365." } })
    }

    $connectors = @(Get-InboundConnector)
    $script:Snapshot.InboundConnectors = $connectors
    $ef = @($connectors | Where-Object { $_.Enabled -and ($_.EFSkipLastIP -or @($_.EFSkipIPs | Where-Object { $_ }).Count) })
    if ($thirdParty) {
        if ($ef) {
            $partial = @($ef | Where-Object { @($_.EFUsers | Where-Object { $_ }).Count })
            Add-Finding -Area 'Mail routing' -Object (($ef | ForEach-Object { $_.Name }) -join ', ') -Setting 'Enhanced Filtering for Connectors' -Current $(if ($partial) { 'On for some users only' } else { 'On' }) `
                -Expected 'On for the entire organization' -Result $(if ($partial) { 'Review' } else { 'Pass' }) -Severity Low -Source 'MS-EF' -Portal 'https://security.microsoft.com/skiplisting'
        } else {
            Add-Finding -Area 'Mail routing' -Object ($thirdParty -join ', ') -Setting 'Enhanced Filtering for Connectors' -Current 'Off' -Expected 'On' -Result Fail -Severity Medium -Source 'MS-EF' `
                -Portal 'https://security.microsoft.com/skiplisting' -Note 'With a filter in front of Microsoft 365, every message appears to come from the filter, so SPF/DMARC and spoof detection cannot work. Turn on Enhanced Filtering on the inbound connector for that service (skip the last IP, or list its IPs); Microsoft suggests testing on a few users first. Not changed automatically.'
        }
    } elseif ($connectors) {
        foreach ($c in $connectors | Where-Object { $_.Enabled -and [string]$_.ConnectorType -eq 'Partner' }) {
            Add-Finding -Area 'Mail routing' -Object $c.Name -Setting 'Inbound partner connector' -Current ("From $(Format-Value $c.SenderIPAddresses) $(Format-Value $c.SenderDomains)".Trim()) -Result Review -Severity Low `
                -Portal 'https://admin.exchange.microsoft.com/#/connectors' -Note 'MX points straight to Microsoft 365. If this connector is left over from a previous filtering service (for example AppRiver), remove it and any SCL -1 rules that go with it.'
        }
    }
}

function Test-EmailAuthentication {
    if (-not $script:DnsAvailable) {
        Add-Finding -Area 'Email authentication' -Object 'DNS' -Setting 'SPF, DKIM, DMARC, MX' -Result Info -Note 'Resolve-DnsName is not available on this computer, so DNS checks were skipped. Run on Windows to include them.'
    }
    $dkimAll = @{}
    foreach ($c in @(Get-DkimSigningConfig)) { $dkimAll[([string]$c.Domain).ToLower()] = $c }
    $script:Snapshot.Dkim = @($dkimAll.Values)
    $dkimPortal = 'https://security.microsoft.com/authentication?viewid=DKIM'

    foreach ($d in $script:CustomDomains) {
        $sending = $script:SendingDomains -contains $d
        $parked  = -not $sending -and $script:DomainMx[$d] -eq 'None'
        $use     = if ($sending) { 'sending' } elseif ($parked) { 'parked (no mailboxes, no MX)' } else { 'receive only (no mailbox uses it as primary)' }

        # SPF
        if ($script:DnsAvailable) {
            $spf = @(Get-TxtRecord $d '^v=spf1(\s|$)')
            $want = if ($parked) { 'v=spf1 -all' } else { 'v=spf1 include:spf.protection.outlook.com -all' }
            if ($spf.Count -eq 0) {
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'SPF' -Current '(none)' -Expected $want -Result Fail -Severity $(if ($parked) { 'Medium' } else { 'High' }) -Source 'MS-SPF' `
                    -Note "Domain is $use. Publish the TXT record at the DNS host, adding any other services that send as this domain. CISA MS.EXO.2.2v3."
            } elseif ($spf.Count -gt 1) {
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'SPF' -Current ($spf -join ' | ') -Expected 'Exactly one SPF record' -Result Fail -Severity High -Source 'MS-SPF' `
                    -Note 'More than one SPF record makes SPF fail (permerror) everywhere. Merge them into one.'
            } else {
                $rec  = $spf[0]
                $info = Get-SpfInfo $d
                $issues = @(); $sev = ''
                $all = if ($rec -match '(^|\s)([-~?+]?)all\s*$') { if ($Matches[2]) { $Matches[2] } else { '+' } } elseif ($rec -match 'redirect=') { 'redirect' } else { 'none' }
                switch ($all) {
                    '-'        { }
                    '~'        { $issues += 'ends in ~all; Microsoft recommends -all so DMARC can act on SPF failures (CISA accepts ~all)'; if (-not $sev) { $sev = 'Low' } }
                    'redirect' { }
                    '?'        { $issues += 'ends in ?all (neutral), which protects nothing'; $sev = 'Medium' }
                    default    { $issues += "ends in $(if ($all -eq '+') { '+all, which authorizes every server on the internet' } else { 'no all mechanism' })"; $sev = 'High' }
                }
                if (-not $parked -and $sending -and $info.Includes -notcontains 'spf.protection.outlook.com') { $issues += 'does not include spf.protection.outlook.com, so mail sent from Microsoft 365 fails SPF'; $sev = 'High' }
                if ($info.Lookups -gt 10) { $issues += "needs $($info.Lookups) DNS lookups; over 10 makes SPF fail (permerror)"; $sev = 'High' }
                elseif ($info.Lookups -ge 9) { $issues += "needs $($info.Lookups) of the 10 allowed DNS lookups" ; if (-not $sev) { $sev = 'Low' } }
                if ($info.Error) { $issues += $info.Error; if ($sev -ne 'High') { $sev = 'Medium' } }
                if ($parked -and $rec -notmatch '^v=spf1\s+-all\s*$') { $issues += 'domain is parked; use v=spf1 -all'; if (-not $sev) { $sev = 'Low' } }
                $result = if (-not $issues) { 'Pass' } elseif ($sev -in 'High', 'Medium') { 'Fail' } else { 'Review' }
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'SPF' -Current $rec -Expected $want -Result $result -Severity $sev -Source 'MS-SPF' `
                    -Note $(if ($issues) { "Record $($issues -join '; '). Fix at the DNS host." } else { "$($info.Lookups) DNS lookups." })
            }
        }

        # DKIM: only meaningful for domains that send
        $cfg = $dkimAll[$d]
        if (-not $sending) {
            Add-Finding -Area 'Email authentication' -Object $d -Setting 'DKIM' -Current $(if ($cfg -and $cfg.Enabled) { 'Enabled' } else { 'Not enabled' }) -Result Info -Source 'MS-DKIM' `
                -Note "Domain is $use; Microsoft does not recommend DKIM records for domains that do not send mail."
        } elseif ($cfg -and $cfg.Enabled) {
            Add-Finding -Area 'Email authentication' -Object $d -Setting 'DKIM' -Current "Enabled ($($cfg.Status))" -Result Pass -Source 'MS-DKIM'
        } elseif ($cfg) {
            $found = 0
            if ($script:DnsAvailable) {
                foreach ($n in 1, 2) {
                    $target = ([string]$cfg."Selector${n}CNAME").TrimEnd('.').ToLower()
                    $have   = @(Get-DnsRecord "selector$n._domainkey.$d" CNAME | ForEach-Object { ([string]$_.NameHost).TrimEnd('.').ToLower() })
                    if ($target -and $have -contains $target) { $found++ }
                }
            }
            $published = $found -eq 2
            $f = Add-Finding -Area 'Email authentication' -Object $d -Setting 'DKIM' -Current "Disabled ($($cfg.Status))" -Expected 'Enabled' -Result Fail -Severity Medium -Source 'MS-DKIM' -Portal $dkimPortal -PassThru `
                -Note $(if ($published) { 'CNAME records are published, so -Apply enables signing.' }
                        else { "Publish these CNAME records at the DNS host, then run again: selector1._domainkey.$d -> $($cfg.Selector1CNAME); selector2._domainkey.$d -> $($cfg.Selector2CNAME). CISA MS.EXO.3.1v1." })
            if ($published) { Add-Change -Target "DKIM: $d" -Description 'Enable DKIM signing' -Findings $f -Steps @(@{ Cmdlet = 'Set-DkimSigningConfig'; Params = [ordered]@{ Identity = $d; Enabled = $true } }) }
            else { $f.Fix = 'Manual' }
        } else {
            $f = Add-Finding -Area 'Email authentication' -Object $d -Setting 'DKIM' -Current 'Not configured (mail is signed with the onmicrosoft.com domain, which does not align for DMARC)' -Expected 'Enabled' -Result Fail -Severity Medium -Source 'MS-DKIM' -Portal $dkimPortal -PassThru `
                -Note '-Apply creates the DKIM keys (signing stays off) and shows the two CNAME records to publish; run again after publishing to enable signing. CISA MS.EXO.3.1v1.'
            Add-Change -Target "DKIM: $d" -Description 'Create DKIM keys (signing enabled on a later run, once the CNAME records are published)' -Findings $f -After 'DkimCnames' -Domain $d `
                -Steps @(@{ Cmdlet = 'New-DkimSigningConfig'; Params = [ordered]@{ DomainName = $d; Enabled = $false; KeySize = 2048 } })
        }

        # DMARC
        if ($script:DnsAvailable) {
            $dm = @(Get-TxtRecord "_dmarc.$d" '^v=DMARC1')
            $want = if ($sending) { 'v=DMARC1; p=reject; rua=mailto:<reporting address>' } else { 'v=DMARC1; p=reject;' }
            if ($dm.Count -eq 0) {
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'DMARC' -Current '(none)' -Expected $want -Result Fail -Severity $(if ($sending) { 'High' } else { 'Medium' }) -Source 'MS-DMARC' `
                    -Note $(if ($sending) { 'Anyone can send mail that appears to come from this domain. Start with p=none and a rua reporting address, then move to quarantine and reject as Microsoft describes. CISA MS.EXO.4.1v1.' }
                            else { "Domain is $use; Microsoft recommends p=reject for domains that never send mail." })
            } elseif ($dm.Count -gt 1) {
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'DMARC' -Current ($dm -join ' | ') -Expected 'Exactly one DMARC record' -Result Fail -Severity High -Source 'MS-DMARC' -Note 'Multiple DMARC records cause receivers to ignore DMARC.'
            } else {
                $tags = @{}
                foreach ($kv in ($dm[0] -split ';')) { if ($kv -match '^\s*(\w+)\s*=\s*(.*?)\s*$') { $tags[$Matches[1].ToLower()] = $Matches[2] } }
                $issues = @(); $sev = ''
                switch ($tags['p']) {
                    'reject'     { }
                    'quarantine' { $issues += 'p=quarantine; the goal is p=reject once reports are clean'; $sev = 'Low' }
                    'none'       { $issues += 'p=none only monitors; move to quarantine, then reject'; $sev = 'Medium' }
                    default      { $issues += "invalid p= value '$($tags['p'])'"; $sev = 'High' }
                }
                if ($tags['pct'] -and ($tags['pct'] -as [int]) -lt 100) { $issues += "pct=$($tags['pct']) applies the policy to only part of the failing mail"; if (-not $sev) { $sev = 'Low' } }
                if ($sending -and -not $tags['rua']) { $issues += 'no rua= aggregate report address, so failures go unseen'; if (-not $sev) { $sev = 'Low' } }
                if (-not $sending -and $tags['p'] -ne 'reject') { $issues += 'domain does not send mail, so p=reject is safe'; if ($sev -ne 'High') { $sev = 'Medium' } }
                $result = if (-not $issues) { 'Pass' } elseif ($sev -in 'High', 'Medium') { 'Fail' } else { 'Review' }
                Add-Finding -Area 'Email authentication' -Object $d -Setting 'DMARC' -Current $dm[0] -Expected $want -Result $result -Severity $sev -Source 'MS-DMARC' `
                    -Note $(if ($issues) { "$($issues -join '; '). CISA MS.EXO.4.2v1 requires p=reject." } else { '' })
            }
        }
    }

    # The onmicrosoft.com domain: Microsoft handles SPF and DKIM, but DMARC is the tenant's to add
    if ($script:DnsAvailable -and $script:InitialDomain) {
        $dm = @(Get-TxtRecord "_dmarc.$($script:InitialDomain)" '^v=DMARC1')
        Add-Finding -Area 'Email authentication' -Object $script:InitialDomain -Setting 'DMARC' -Current $(if ($dm) { $dm[0] } else { '(none)' }) -Expected 'v=DMARC1; p=reject' `
            -Result $(if ($dm -and $dm[0] -match 'p=reject') { 'Pass' } else { 'Review' }) -Severity Low -Source 'MS-DMARC' -Portal 'https://admin.microsoft.com/Adminportal/Home#/Domains' `
            -Note 'If nobody sends from the onmicrosoft.com address, add TXT _dmarc = "v=DMARC1; p=reject" in the Microsoft 365 admin center > Domains > (onmicrosoft.com domain) > DNS records.'
    }
}

function Test-UserExperience {
    $ext = @(Get-ExternalInOutlook) | Select-Object -First 1
    $script:Snapshot.ExternalInOutlook = $ext
    if ($ext.Enabled) {
        Add-Finding -Area 'User experience' -Object 'Outlook' -Setting 'External sender tag' -Current 'On' -Result Pass -Source 'CISA-EXO'
    } else {
        $f = Add-Finding -Area 'User experience' -Object 'Outlook' -Setting 'External sender tag' -Current 'Off' -Expected 'On' -Result Fail -Severity Medium -Source 'CISA-EXO' -PassThru `
            -Note 'Shows an External tag on mail from outside the organization. CISA MS.EXO.7.1v1 (SHALL). Takes 24-48 hours to appear in Outlook.'
        Add-Change -Target 'Outlook: external sender tag' -Description 'Turn on the External tag in Outlook' -Findings $f -Steps @(@{ Cmdlet = 'Set-ExternalInOutlook'; Params = [ordered]@{ Enabled = $true } })
    }

    try {
        $rsp = Get-ReportSubmissionPolicy -ErrorAction Stop | Select-Object -First 1
        $script:Snapshot.ReportSubmissionPolicy = $rsp
        $to = @()
        if ($rsp.EnableReportToMicrosoft) { $to += 'Microsoft' }
        $box = @(@($rsp.ReportJunkAddresses) + @($rsp.ReportPhishAddresses) + @($rsp.ReportNotJunkAddresses) | Where-Object { $_ } | Sort-Object -Unique)
        if ($box) { $to += "mailbox $($box -join ', ')" }
        if ($rsp.EnableThirdPartyAddress) { $to += "third-party tool $(Format-Value $rsp.ThirdPartyReportAddresses)" }
        Add-Finding -Area 'User experience' -Object 'User reported messages' -Setting 'Where reports go' -Current $(if ($to) { $to -join ' and ' } else { 'Not configured' }) -Result Info `
            -Portal 'https://security.microsoft.com/securitysettings/userSubmission'
    } catch { Write-Verbose "Report submission policy not readable: $(Get-ErrorText $_)" }
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Block)
    Write-Host "  Checking $Name..." -ForegroundColor DarkGray
    try { & $Block }
    catch {
        Add-Finding -Area 'Audit failed' -Object $Name -Setting 'Check' -Result Review -Severity Medium -Note "Could not complete: $(Get-ErrorText $_). Review this area in the portal."
        Write-Warning "  $Name failed: $(Get-ErrorText $_)"
    }
}

#endregion

#region Apply

function Invoke-Changes {
    param($TenantChanges)
    foreach ($c in $TenantChanges) {
        Write-Host "  [$($c.Id)] $($c.Target): $($c.Description)" -ForegroundColor White
        try {
            foreach ($s in $c.Steps) {
                $p = $s.Params
                & $s.Cmdlet @p -ErrorAction Stop | Out-Null
            }
            $c.Status = 'Applied'
            Write-Host '         Applied' -ForegroundColor Green
        } catch {
            $c.Status = 'Failed'
            $c.Error  = Get-ErrorText $_
            Write-Host "         FAILED: $($c.Error)" -ForegroundColor Red
        }
        foreach ($f in $Findings | Where-Object { $_.ChangeId -eq $c.Id -and $_.Tenant -eq $c.Tenant }) {
            if ($c.Status -eq 'Applied') { $f.Result = 'Fixed' } else { $f.Result = 'Fix failed'; $f.Note = "$($f.Note) Change failed: $($c.Error)".Trim() }
        }
        if ($c.Status -eq 'Applied' -and $c.After -eq 'DkimCnames') {
            try {
                $cfg = Get-DkimSigningConfig -Identity $c.Domain
                $msg = "Publish at the DNS host, then run again to enable signing: selector1._domainkey.$($c.Domain) CNAME $($cfg.Selector1CNAME); selector2._domainkey.$($c.Domain) CNAME $($cfg.Selector2CNAME)"
                Add-Finding -Area 'Email authentication' -Object $c.Domain -Setting 'DKIM CNAME records to publish' -Current "$($cfg.Selector1CNAME), $($cfg.Selector2CNAME)" -Result Review -Severity Medium -Source 'MS-DKIM' -Note $msg
                Write-Host "         $msg" -ForegroundColor Yellow
            } catch { Write-Warning "Could not read the new DKIM keys for $($c.Domain): $(Get-ErrorText $_)" }
        }
    }
}

#endregion

#region Report

$ResultColors = @{ 'Fix failed' = 'Red'; Fail = 'Red'; Review = 'Yellow'; Fixed = 'Green'; Info = 'DarkGray'; Pass = 'Green' }

function Write-ConsoleReport {
    param($Items, $TenantChanges)
    $counts = $Items | Group-Object Result | Sort-Object { $ResultOrder[$_.Name] } | ForEach-Object { "$($_.Count) $($_.Name)" }
    Write-Host ''
    Write-Host ('-' * 78) -ForegroundColor White
    Write-Host "$($script:Tenant.Name) - $Level baseline - $($counts -join ', ')" -ForegroundColor White
    Write-Host ('-' * 78) -ForegroundColor White

    foreach ($area in $Items | Group-Object Area) {
        $bad  = @($area.Group | Where-Object { $_.Result -in 'Fail', 'Review', 'Fix failed', 'Fixed' } | Sort-Object { $ResultOrder[$_.Result] }, { $SeverityOrder[$_.Severity] })
        $pass = @($area.Group | Where-Object Result -eq 'Pass').Count
        $order = $area.Group | Where-Object { $_.Object -eq 'Policy order' } | Select-Object -First 1
        $info  = @($area.Group | Where-Object { $_.Result -eq 'Info' -and $_.Object -ne 'Policy order' -and $_.Setting -ne 'Policy type' })
        Write-Host ''
        Write-Host ("{0}  ({1} pass, {2} to review)" -f $area.Name.ToUpper(), $pass, $bad.Count) -ForegroundColor Cyan
        if ($order) { Write-Host "  Order: $($order.Current)" -ForegroundColor DarkGray }
        foreach ($f in $info) { Write-Host "  [INFO] $($f.Object) > $($f.Setting)$(if ($f.Current -ne '') { ": $($f.Current)" })" -ForegroundColor DarkGray }
        foreach ($f in $bad) {
            $tag = ('[{0}{1}]' -f $f.Result.ToUpper(), $(if ($f.Severity) { " $($f.Severity)" })).PadRight(16)
            $cur = if ($f.Current -ne '') { $f.Current } else { '(none)' }
            $exp = if ($f.Expected -ne '') { " (expected $($f.Expected))" } else { '' }
            $fix = if ($f.Fix -and $f.Result -in 'Fail', 'Review') { "  [$($f.Fix)]" } else { '' }
            Write-Host "  $tag" -ForegroundColor $ResultColors[$f.Result] -NoNewline
            Write-Host "$($f.Object) > $($f.Setting): $cur$exp$fix"
            if ($f.Note) { Write-Host "                    $($f.Note)" -ForegroundColor DarkGray }
        }
    }

    $planned = @($TenantChanges | Where-Object Status -eq 'Planned')
    if ($planned -and -not $Apply) {
        Write-Host ''
        Write-Host "$($planned.Count) change(s) -Apply would make:" -ForegroundColor White
        foreach ($c in $planned) {
            Write-Host "  [$($c.Id)] $($c.Target): $($c.Description)"
            Write-Host "         $($c.Command)" -ForegroundColor DarkGray
        }
    }
}

function Export-HtmlReport {
    param([string]$Path)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><title>Email Threat Protection</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fff}
h1{font-size:22px}h2{font-size:18px;margin-top:32px;border-bottom:1px solid #ccc;padding-bottom:4px}h3{font-size:15px;margin-top:20px}
table{border-collapse:collapse;width:100%;font-size:13px;margin-bottom:8px}th,td{border:1px solid #ddd;padding:6px;vertical-align:top;text-align:left}
th{background:#f3f3f3}.small{color:#555;font-size:12px}.r{font-weight:600;white-space:nowrap}
.Fail,.Fix-failed{background:#fde2e1}.Review{background:#fff4ce}.Fixed,.Pass{background:#dff6dd}.Info{color:#555}
details summary{cursor:pointer;color:#0b5cad;font-size:13px;margin:4px 0}code{font-size:12px}
</style></head><body>
<h1>Email threat protection: $Level baseline</h1>
<p class="small">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Mode: $(if ($Apply) { 'audit and apply' } else { 'audit only; nothing was changed' }).
Values from <a href="$($Sources['MS-REC'])">Microsoft's recommended settings</a> (updated 2026-08-10) unless a finding cites another source.
A setting that is already stricter than the baseline passes.</p>
"@)
    foreach ($t in $Findings | Group-Object Tenant) {
        $counts = ($t.Group | Group-Object Result | Sort-Object { $ResultOrder[$_.Name] } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        [void]$sb.Append("<h2>$(& $enc $t.Name) <span class='small'>$counts</span></h2>")
        $tc = @($Changes | Where-Object Tenant -eq $t.Name)
        if ($tc) {
            [void]$sb.Append("<h3>Changes</h3><table><tr><th>Id</th><th>Status</th><th>Target</th><th>Description</th><th>Command</th></tr>")
            foreach ($c in $tc) {
                $st = if ($c.Error) { "$($c.Status): $($c.Error)" } else { $c.Status }
                [void]$sb.Append("<tr><td>$($c.Id)</td><td class='r'>$(& $enc $st)</td><td>$(& $enc $c.Target)</td><td>$(& $enc $c.Description)</td><td><code>$(& $enc $c.Command)</code></td></tr>")
            }
            [void]$sb.Append('</table>')
        }
        foreach ($area in $t.Group | Group-Object Area) {
            [void]$sb.Append("<h3>$(& $enc $area.Name)</h3>")
            $rows = $area.Group | Sort-Object { $ResultOrder[$_.Result] }, { $SeverityOrder[$_.Severity] }
            $main = @($rows | Where-Object Result -ne 'Pass')
            $pass = @($rows | Where-Object Result -eq 'Pass')
            $head = '<table><tr><th>Result</th><th>Policy / object</th><th>Setting</th><th>Current</th><th>Expected</th><th>Fix</th><th>Notes</th></tr>'
            $row = {
                param($f)
                $note = & $enc $f.Note
                if ($f.SourceUrl) { $note += " <a href='$(& $enc $f.SourceUrl)' target='_blank'>[$(& $enc $f.Source)]</a>" }
                if ($f.Portal)    { $note += " <a href='$(& $enc $f.Portal)' target='_blank'>[portal]</a>" }
                $res = if ($f.Severity) { "$($f.Result) ($($f.Severity))" } else { $f.Result }
                "<tr class='$($f.Result -replace ' ', '-')'><td class='r'>$res</td><td>$(& $enc $f.Object)</td><td>$(& $enc $f.Setting)</td><td>$(& $enc $f.Current)</td><td>$(& $enc $f.Expected)</td><td>$(& $enc $f.Fix) $($f.ChangeId)</td><td class='small'>$note</td></tr>"
            }
            if ($main) { [void]$sb.Append($head); foreach ($f in $main) { [void]$sb.Append((& $row $f)) }; [void]$sb.Append('</table>') }
            if ($pass) {
                [void]$sb.Append("<details><summary>$($pass.Count) passing</summary>$head")
                foreach ($f in $pass) { [void]$sb.Append((& $row $f)) }
                [void]$sb.Append('</table></details>')
            }
        }
    }
    [void]$sb.Append('<h2>Sources</h2><ul>')
    foreach ($k in $Sources.Keys) { [void]$sb.Append("<li><a href='$($Sources[$k])'>$(& $enc $SourceNames[$k])</a></li>") }
    [void]$sb.Append('</ul></body></html>')
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}

#endregion

#region Main

# Exchange Online Management v3 (REST-based, modern auth)
if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
    $mod = Get-Module -ListAvailable -Name ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod -or $mod.Version -lt [version]'3.0.0') {
        Write-Host 'Installing ExchangeOnlineManagement...'
        try { Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop }
        catch { throw "Failed to install ExchangeOnlineManagement: $($_.Exception.Message)" }
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
}

$connectArgs = @{ ShowBanner = $false }
# -DisableWAM avoids sign-in failures in elevated or non-standard terminals (EXO module 3.7.2+)
if ((Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('DisableWAM')) { $connectArgs.DisableWAM = $true }
if ($UserPrincipalName) { $connectArgs.UserPrincipalName = $UserPrincipalName }

$script:DnsAvailable = [bool](Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$findingsCsv = Join-Path $OutputPath 'Findings.csv'
$changesCsv  = Join-Path $OutputPath 'Changes.csv'
$htmlPath    = Join-Path $OutputPath 'Report.html'

$targets = @($DelegatedOrganization | Where-Object { $_ } | ForEach-Object { $_.Trim() })
if (-not $targets) { $targets = @('') }   # '' = the tenant you sign in to
$i = 0
foreach ($org in $targets) {
    $i++
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host "[$i/$($targets.Count)] Connecting to $(if ($org) { $org } else { 'your tenant' }) - sign in via the window that appears." -ForegroundColor White

    $script:Tenant   = [pscustomobject]@{ Name = $(if ($org) { $org } else { 'Home tenant' }) }
    $script:Snapshot = [ordered]@{}
    $script:Presets  = @{}
    $script:PhishSimValues   = @()
    $script:ExternalForwards = @()
    $script:DomainMx = @{}
    $script:MailDomains = @(); $script:CustomDomains = @(); $script:SendingDomains = @(); $script:Mdo = $false
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $a = $connectArgs.Clone()
        if ($org) { $a.DelegatedOrganization = $org }
        Connect-ExchangeOnline @a
        $orgConfig = Get-OrganizationConfig
        $script:Tenant.Name = if ($orgConfig.DisplayName) { "$($orgConfig.DisplayName) ($($orgConfig.Name))" } else { [string]$orgConfig.Name }
        Write-Host "Connected to $($script:Tenant.Name)" -ForegroundColor Green
    } catch {
        Add-Finding -Area 'Audit failed' -Object $script:Tenant.Name -Setting 'Sign in' -Result Review -Severity High `
            -Note "NOTHING WAS CHECKED. Could not connect: $(Get-ErrorText $_). Check GDAP roles (Exchange Administrator or Security Reader) for this customer."
        Write-Warning "Could not connect to $($script:Tenant.Name): $(Get-ErrorText $_)"
        continue
    }

    # Order matters: context and forwarding feed the policy checks; allow lists feed the redundancy notes
    Invoke-Check 'tenant and license'         { Initialize-TenantContext }
    if (-not $script:MailDomains) { Write-Warning 'Could not read the tenant basics; skipping the rest of this tenant.'; continue }
    Invoke-Check 'mailbox forwarding'         { Test-Forwarding }
    Invoke-Check 'phishing simulation and allow lists' { Test-AllowLists }
    Invoke-Check 'preset security policies'   { Test-PresetPolicies }
    foreach ($def in $PolicyTypes) {
        if ($def.Mdo -and -not $script:Mdo) { continue }
        Invoke-Check $def.Area.ToLower() { Test-PolicyType -Def $def }
    }
    Invoke-Check 'Safe Links coverage'        { Test-SafeLinksBaseline }
    Invoke-Check 'Defender global settings'   { Test-DefenderGlobal }
    Invoke-Check 'connection filter'          { Test-ConnectionFilter }
    Invoke-Check 'mail flow rules'            { Test-TransportRules }
    Invoke-Check 'mail routing'               { Test-MailRouting }
    Invoke-Check 'SPF, DKIM and DMARC'        { Test-EmailAuthentication }
    Invoke-Check 'Outlook and reporting'      { Test-UserExperience }

    $safeName = ($script:Tenant.Name -replace '[^\w.-]+', '_').Trim('_')
    try { $script:Snapshot | ConvertTo-Json -Depth 4 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $OutputPath "Snapshot $safeName.json") -Encoding UTF8 }
    catch { Write-Warning "Could not save the policy snapshot: $(Get-ErrorText $_)" }

    $tenantChanges = @($Changes | Where-Object Tenant -eq $script:Tenant.Name)
    Write-ConsoleReport -Items @($Findings | Where-Object Tenant -eq $script:Tenant.Name) -TenantChanges $tenantChanges

    if ($Apply -and $tenantChanges) {
        Write-Host ''
        Write-Host "$($tenantChanges.Count) change(s) to apply to $($script:Tenant.Name):" -ForegroundColor White
        foreach ($c in $tenantChanges) { Write-Host "  [$($c.Id)] $($c.Target): $($c.Description)" }
        $go = $Force
        if (-not $go) { $go = (Read-Host 'Apply these changes? [y/N]') -match '^(y|yes)$' }
        if ($go) {
            Invoke-Changes -TenantChanges $tenantChanges
            Write-Host 'Changes can take up to a few hours to take effect. Run the audit again later to confirm.' -ForegroundColor DarkGray
        } else {
            foreach ($c in $tenantChanges) { $c.Status = 'Skipped' }
            Write-Host 'Skipped; nothing was changed.' -ForegroundColor Yellow
        }
    } elseif ($Apply) {
        Write-Host 'Nothing to change.' -ForegroundColor Green
    }
}

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$Findings | Sort-Object Tenant, Area, { $ResultOrder[$_.Result] }, { $SeverityOrder[$_.Severity] } |
    Export-Csv -LiteralPath $findingsCsv -NoTypeInformation -Encoding UTF8
$Changes | Select-Object Tenant, Id, Status, Target, Description, Command, Error |
    Export-Csv -LiteralPath $changesCsv -NoTypeInformation -Encoding UTF8
Export-HtmlReport -Path $htmlPath

Write-Host ''
Write-Host "Findings: $findingsCsv"
Write-Host "Changes:  $changesCsv"
Write-Host "Report:   $htmlPath"
Write-Host "Snapshot: $OutputPath (policy settings as they were before any change)"

#endregion
