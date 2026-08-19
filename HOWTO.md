# How to Use This Repository

This guide walks through how to find a script, understand what it does, download it, and run it safely. It does not try to document every script individually — instead it teaches you the pattern so you can apply it to any script in the library.

---

## 1. Finding the Right Script

Scripts are organized by platform and function. Start at the folder README for the platform you need:

- [`Windows/README.md`](Windows/README.md) — applications, OS, security, user management, networking, reporting, CVE mitigations
- [`Mac/README.md`](Mac/README.md) — agent installs, OS config, security
- [`Linux/README.md`](Linux/README.md) — agent installs, diagnostic tools
- [`Microsoft 365/README.md`](Microsoft%20365/README.md) — Exchange Online, Entra ID, phishing simulation, reporting

Each folder README contains an index table listing every script with a short description. Scan the table to find what you need, then click through to the script file.

Alternatively, use GitHub's search (the **Search or jump to...** box at the top of any GitHub page) and search within the `rttappdevelopers/scripts` repository. Script filenames follow a consistent `Action Product` pattern (e.g., `Install ConnectSecure Agent`, `Get Mailbox Rules and Forwards`) so keyword searches are usually effective.

---

## 2. Reading a Script Before Running It

**Always read a script before you run it.** Every script in this library includes a comment block at the top that describes:

- **What it does** (`.SYNOPSIS` / `.DESCRIPTION` for PowerShell; `# Description:` for Bash/Python)
- **Parameters it accepts** (`.PARAMETER` entries, or argument descriptions in the header)
- **Example usage** (`.EXAMPLE` entries, or usage comments)
- **Notes** about prerequisites, required modules, or expected behavior

In GitHub, click the script filename to open the file viewer, then read the header comment before doing anything else.

---

## 3. Downloading a Script

### Option A — Copy and paste from GitHub (quickest for one-off use)

1. Open the script file in GitHub.
2. Click the **Raw** button (top-right of the file viewer) to see the plain text.
3. Select all, copy, and paste into a new file on the target machine, or directly into PowerShell ISE or VS Code.

### Option B — Download via PowerShell (`Invoke-WebRequest`)

Click **Raw** in GitHub to get the raw file URL, then run:

```powershell
Invoke-WebRequest -Uri "<raw-url>" -OutFile "C:\Temp\ScriptName.ps1"
```

**Example:**

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/rttappdevelopers/scripts/main/Windows/Applications/Install%20AnyDesk.ps1" -OutFile "C:\Temp\Install AnyDesk.ps1"
```

> **Tip:** Raw URLs follow this pattern:
> `https://raw.githubusercontent.com/rttappdevelopers/scripts/main/<folder>/<filename>`
> Spaces in folder or file names must be encoded as `%20`.

### Option C — Download via `curl` (PowerShell 7+ or Bash/Mac/Linux)

```bash
curl -L -o "Install AnyDesk.ps1" "https://raw.githubusercontent.com/rttappdevelopers/scripts/main/Windows/Applications/Install%20AnyDesk.ps1"
```

### Option D — Clone the full repository (best for ongoing use)

If you regularly use scripts from this library, clone the repo once and pull updates:

```powershell
git clone https://github.com/rttappdevelopers/scripts.git
```

Then update any time with:

```powershell
cd scripts
git pull
```

---

## 4. Running a Script

### Choosing your execution environment

| Environment | When to use |
|---|---|
| **NinjaOne RMM** | Deploying to many endpoints silently, or running at SYSTEM level. No interaction required. |
| **PowerShell (terminal)** | Quick one-off execution on a local or remote machine when you don't need a visual editor. |
| **PowerShell ISE** | Running and editing `.ps1` scripts interactively. Good for scripts that produce a lot of output you want to scroll through. Lets you inspect variables and step through code. |
| **VS Code** | Preferred for reading, editing, or developing scripts. The PowerShell extension gives you syntax highlighting, IntelliSense, and an integrated terminal. Scripts generally run more reliably here than in a plain terminal. |

> **ISE and VS Code tip:** Both environments let you open the script file, review the header and parameters, then press **F5** (or use the Run button) to execute it in a controlled session. This is significantly safer than pasting into a terminal blindly.

---

### Running as Administrator

Many scripts require an elevated session. To check: if the script contains `#Requires -RunAsAdministrator` near the top, or its description says it modifies system settings, services, or the registry — it needs admin rights.

**PowerShell terminal (elevated):**
Right-click PowerShell → **Run as Administrator**, then navigate to the script and run it.

**PowerShell ISE (elevated):**
Right-click PowerShell ISE in the Start menu → **Run as Administrator**, then open the script file.

**VS Code (elevated):**
Close VS Code, then right-click its shortcut → **Run as Administrator**. The integrated terminal will inherit the elevated context.

> Running without elevation when it's required will typically produce "Access Denied" errors mid-script. It's better to start elevated than to restart partway through.

---

### Execution Policy

Windows blocks unsigned scripts by default. If you see a message like `is not digitally signed` or `cannot be loaded because running scripts is disabled`, resolve it with:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

This applies only to the current PowerShell session — it does not permanently change system policy and is the appropriate approach for running scripts interactively on a technician machine.

Alternatively, if you downloaded the file from GitHub and Windows flagged it as coming from the internet, unblock it first:

```powershell
Unblock-File -Path "C:\Temp\Install AnyDesk.ps1"
```

---

### Passing Parameters

Scripts accept input through parameters. The header comment (`.PARAMETER` section) documents each one. Parameters are passed at the command line:

```powershell
.\Install-AnyDesk.ps1 -Silent -Version "8.0.8"
```

Many scripts also read NinjaOne environment variables as an alternative to parameters — see the script header for details.

---

## 5. After Running

- Read the console output. Scripts log what they did and any errors encountered.
- If the script exited with an error, the output will say so. Check the message before retrying.
- For scripts that produce a report or output file, the header will tell you where to find it.

---

## Troubleshooting NinjaOne Custom Field Writes

If a script runs cleanly and prints the right value to the console, but the NinjaOne custom field never updates, check these in order:

1. **The script must run as root/SYSTEM.** Both `Ninja-Property-Set` (Windows) and `ninjarmm-cli` (Mac/Linux) live in locations regular users can't access. When testing manually on a Mac, run with `sudo`; on Windows, run PowerShell as Administrator. Scripts deployed through NinjaOne itself already run at SYSTEM/root, so this only bites during manual testing.
2. **The custom field's permissions must allow write access from scripts.** In NinjaOne, open the field's settings and confirm the *Automations*/*Scripting* permission is set to **Read/Write**, not Read-Only. A read-only field silently discards writes.
3. **The field name must match exactly** (case-sensitive) the name used in `Ninja-Property-Set` / `ninjarmm-cli set`, not the human-readable label shown in the UI.
4. **The field type must support writes.** Most types (Text, Checkbox, Dropdown, etc.) are read/write, but a few (Attachment, Device drop-down/multi-select, Organization drop-down/multi-select) are read-only via the CLI/API regardless of permission settings.
5. **Don't suppress stderr while debugging.** Several scripts in this repo redirect `ninjarmm-cli`/`Ninja-Property-Set` errors to `/dev/null` or `$null` so a missing agent doesn't fail the whole script. That also hides the real error (e.g., permission denied) if the field write fails for another reason - temporarily remove the redirect to see the actual message.

On Mac specifically, the CLI binary is at `/Applications/NinjaRMMAgent/programdata/ninjarmm-cli` (not under `NinjaRMMAgent.app`). Reference: [NinjaOne CLI: Custom Fields and Documentation Scripting](https://www.ninjaone.com/docs/scripting-and-automation/command-line-interface-cli/cli-custom-fields-documentation-scripting/).

---

## Questions or Issues

If a script doesn't behave as expected, open its file in GitHub and check whether a more recent version exists (compare the `git log` or the file's commit history). If you find a bug or want to suggest an improvement, see [CONTRIBUTING.md](CONTRIBUTING.md).
