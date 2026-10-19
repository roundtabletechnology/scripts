# Microsoft 365

Scripts for managing Microsoft 365 tenants. These run interactively from a **technician's workstation** — not via RMM — and use modern authentication only (`ExchangeOnlineManagement` v3+, `Microsoft.Graph`).

See [HOWTO.md](../HOWTO.md) for guidance on downloading and running scripts. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the M365 authentication rules and EOL module policy.

---

## Exchange Online

| Script | Description |
|---|---|
| [Add Users to Distribution List.ps1](Exchange%20Online/Add%20Users%20to%20Distribution%20List.ps1) | Bulk-adds users from a CSV to an Exchange distribution group |
| [Configure AppRiver Bypass Filtering.ps1](Exchange%20Online/Configure%20AppRiver%20Bypass%20Filtering.ps1) | Configures Exchange connectors to bypass filtering for AppRiver mail flow |
| [Configure AppRiver Inbound Limit.ps1](Exchange%20Online/Configure%20AppRiver%20Inbound%20Limit.ps1) | Sets inbound rate limits for AppRiver connector |
| [Create Contacts from CSV.ps1](Exchange%20Online/Create%20Contacts%20from%20CSV.ps1) | Creates mail contacts in Exchange Online from a CSV file |
| [Download Message Trace Reports.ps1](Exchange%20Online/Download%20Message%20Trace%20Reports.ps1) | Downloads completed message trace reports from the Security & Compliance Center |
| [Fix Message Trace Encoding.ps1](Exchange%20Online/Fix%20Message%20Trace%20Encoding.ps1) | Fixes character encoding issues in exported message trace CSV files |
| [Get Mailbox Rules and Forwards.ps1](Exchange%20Online/Get%20Mailbox%20Rules%20and%20Forwards.ps1) | Reports all inbox rules and forwarding settings across the tenant |
| [Get Message Trace.ps1](Exchange%20Online/Get%20Message%20Trace.ps1) | Runs a message trace and exports results to CSV |
| [Import AppRiver Users.ps1](Exchange%20Online/Import%20AppRiver%20Users.ps1) | Imports user list from AppRiver into Exchange Online |

## Entra ID

| Script | Description |
|---|---|
| [Get Immutable ID.ps1](Entra%20ID/Get%20Immutable%20ID.ps1) | Retrieves the ImmutableID for a user — used during AD-to-Entra ID identity matching |

## Reporting

| Script | Description |
|---|---|
| [Get Mailbox Usage.ps1](Reporting/Get%20Mailbox%20Usage.ps1) | Exports a mailbox size and usage report for the tenant |

## Security and Compliance

| Script | Description |
|---|---|
| [Audit ConnectWise SkyKick IOCs.ps1](Security%20and%20Compliance/Audit%20ConnectWise%20SkyKick%20IOCs.ps1) | Read-only audit of one or many tenants for the October 2026 ConnectWise Cloud Backup (SkyKick) credential compromise reported by Huntress; reports where to find and disable each finding |
| [Configure Defendify Phishing Simulation.ps1](Security%20and%20Compliance/Configure%20Defendify%20Phishing%20Simulation.ps1) | Whitelists Defendify phishing simulation infrastructure in Microsoft 365 |
| [Configure Phinsec Phishing Simulation.ps1](Security%20and%20Compliance/Configure%20Phinsec%20Phishing%20Simulation.ps1) | Whitelists Phinsec phishing simulation infrastructure in Microsoft 365 |
| [Get MFA Status Report.ps1](Security%20and%20Compliance/Get%20MFA%20Status%20Report.ps1) | Reports MFA enrollment status for all users in the tenant |
