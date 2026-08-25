# RMM

Scripts for managing the NinjaOne RMM platform itself — agent reinstallation and organization-level configuration. These are deployed via NinjaOne or run directly on a managed endpoint.

See [HOWTO.md](../HOWTO.md) for guidance on downloading and running scripts.

---

## Scripts

| Script | Description |
|---|---|
| [Reinstall NinjaRMM Agent.ps1](Reinstall%20NinjaRMM%20Agent.ps1) | Removes the incumbent NinjaOne agent (including Ninja Remote, services, registry entries, and drivers) and installs the new MSP's NinjaRMM agent. Designed for MSP-to-MSP fleet transfers. Runs in two phases: the NinjaOne-side PREPARE phase validates the URL, surveys the machine, downloads and validates the MSI, and records the incumbent's product codes - it never touches the agent. It then hands both the removal and the install to a single self-retrying SYSTEM scheduled task that runs outside the agent's process tree, so nothing destructive can be killed halfway through by the agent teardown. Retrying is safe because the recorded product codes distinguish the old agent from the new one. Accepts the installer URL via hardcoded `$NewMSPInstallerURL`, `-InstallerURL`, or Ninja script variable `installerUrl`; a generic installer plus `-InstallerToken` (script variable `token`/`installerToken`) is supported as an alternative, with `-HostURL` for FedRAMP. Supports `-DryRun` to validate the URL and survey a machine without changing anything. Logs durably to `C:\ProgramData\RTT\NinjaAgentTransfer\`, which is ACLed to SYSTEM and Administrators. |
| [Set Organization UDF from Hostname.ps1](Set%20Organization%20UDF%20from%20Hostname.ps1) | Sets a NinjaOne custom field (UDF) value derived from the device hostname — used to associate devices with organizations during onboarding. |
