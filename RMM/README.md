# RMM

Scripts for managing the NinjaOne RMM platform itself — agent reinstallation and organization-level configuration. These are deployed via NinjaOne or run directly on a managed endpoint.

See [HOWTO.md](../HOWTO.md) for guidance on downloading and running scripts.

---

## Scripts

| Script | Description |
|---|---|
| [Reinstall NinjaRMM Agent.ps1](Reinstall%20NinjaRMM%20Agent.ps1) | Removes the incumbent NinjaOne agent (including Ninja Remote, services, registry entries, and drivers) and installs the RTT NinjaRMM agent. Designed for MSP-to-MSP fleet transfers. Accepts installer URL via hardcoded `$RTTInstallerURL`, `-InstallerURL` parameter, or Ninja script variable `installerUrl` (`$env:installerUrl`). |
| [Set Organization UDF from Hostname.ps1](Set%20Organization%20UDF%20from%20Hostname.ps1) | Sets a NinjaOne custom field (UDF) value derived from the device hostname — used to associate devices with organizations during onboarding. |
