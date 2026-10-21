# Developed by Jeff and Gemini
# NordLayer Install [MAC]
# Get latest version of NordLayer VPN and install it. 
# Uses custom variables for Nord Site ID and Nord Trusted WiFi networks.

Param(
    [Parameter(Mandatory=$false)]
    [string]$NinjaCustomField
)

# 1. Fetch Organization ID from NinjaOne global organization custom field
$OrgID = Ninja-Property-Get nordlayerorgid

# 2. Check if NordLayer is installed via fast Registry lookup instead of slow Win32_Product
$RegPath64 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
$RegPath32 = "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
$Installed = Get-ItemProperty -Path $RegPath64, $RegPath32 -ErrorAction SilentlyContinue | 
             Where-Object { $_.DisplayName -eq "NordLayer" }

if ($Installed) {
    Write-Output "NordLayer is already installed (Version: $($Installed.DisplayVersion)). Skipping installation."
    Exit 0
}

Write-Output "NordLayer not detected. Fetching latest installer metadata..."

# 3. Extract the newest version download URL directly from the NordLayer RSS Feed
$RssUrl = "https://nordlayer.com"

try {
    # Get the latest version of NordLayer VPN from the RSS feed
    $nordLayerURL = "https://downloads.nordlayer.com/win/releases/rss.xml"
    $DownloadUrl = Invoke-RestMethod -Uri $nordLayerURL | Select-Object -First 1 | Select-Object -ExpandProperty link
    $filename = $DownloadUrl.Split('/')[-1]
    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        throw "Download link extracted from RSS feed was empty."
    }
    Write-Output "Successfully retrieved target deployment URL: $DownloadUrl"
}
catch {
    Write-Error "Failed to parse RSS feed. Error: $_"
    Exit 1
}

# 4. Stage the file transfer locally
$TempPath = Join-Path $env:TEMP "$filename"
Write-Output "Downloading NordLayer MSI..."
try {
# Attempt download using Invoke-WebRequest
Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempPath -ErrorAction Stop
}
catch {
Write-Output "Invoke-WebRequest failed. Attempting fallback download via curl.exe..."
# Clean up any partial download artifact before trying curl
if (Test-Path $TempPath) { 
  Remove-Item $TempPath -Force
  }
# Run curl.exe explicitly using standard arguments
# -L follows redirects, -s runs silently, -S shows errors if it fails
curl.exe -L -s -S "$DownloadUrl" -o "$TempPath"
}

# Final verification to ensure the file exists and is not empty before proceeding

if (-not (Test-Path $TempPath) -or (Get-Item $TempPath).Length -eq 0) {
Write-Error "Critical Error: NordLayer installer download failed entirely. Both Invoke-WebRequest and curl.exe failed to retrieve the file."
Exit 1
}

# 5. Dynamically build silent parameters based on Custom Field availability
$BaseArguments = "/i `"$TempPath`" /qn /norestart /l*v `"C:\Windows\Temp\nordlayer_msi.log`""

if ([string]::IsNullOrWhiteSpace($OrgID)) {
    Write-Output "No Organization ID detected in NinjaOne 'nordlayerorgid'. Proceeding with standard silent installation."
    $Arguments = $BaseArguments 
} else {
    Write-Output "NinjaOne Organization ID detected: $OrgID. Embedding into deployment parameters."
    $Arguments = "$BaseArguments ORGANIZATION=$OrgID"
}

# 6. Execute the installation
Write-Output "Executing msiexec with parameters: $Arguments"
$Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru

# 7. Clean up downloaded installer file
if (Test-Path $TempPath) {
    Remove-Item $TempPath -Force
}

# 8. Evaluate execution success
if ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq 3010) {
    Write-Output "NordLayer successfully deployed."
} else {
    Write-Error "NordLayer installation failed with Exit Code: $($Process.ExitCode)"
    Exit 1
}

# Install Software end, Configuration INI Begin

# 1. Fetch the organization level custom field using the native NinjaOne cmdlet
$TrustedNetworks = $null
try {
    $TrustedNetworks = Get-NinjaProperty -Name "NordTrustedNetworks"
} catch {
    Write-Warning "Non-fatal error: Failed to retrieve NinjaOne custom field 'NordTrustedNetworks'. $_"
}

# 2. Proceed only if the custom field contains data
if (-not [string]::IsNullOrWhiteSpace($TrustedNetworks)) {

    # Define target path and prepare file content (without any spaces)
    $TargetDir  = "C:\Program Files (x86)\NordLayer"
    $TargetFile = "$TargetDir\SettingsConfig.ini"
    $FileContent = "AppendTrustedNetworks=$TrustedNetworks"

    try {
        # Verify directory existence; create it if missing
        if (-not (Test-Path -Path $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Write-Host "Created missing directory: $TargetDir"
        }

        # Explicitly delete the existing file if it is already there to ensure a fresh replacement
        if (Test-Path -Path $TargetFile) {
            Remove-Item -Path $TargetFile -Force -ErrorAction SilentlyContinue
            Write-Host "Existing file found and removed for replacement."
        }

        # Create the new file with the specific text string
        $FileContent | Out-File -FilePath $TargetFile -Encoding utf8 -Force
        Write-Host "Successfully replaced and wrote configuration to: $TargetFile"
    } catch {
        Write-Warning "Non-fatal error: Failed to modify NordLayer configuration file. $_"
    }

} else {
    Write-Host "The custom field 'NordTrustedNetworks' is empty. Skipping file creation."
}

# ---Configuration INI end, Enable location services begin


<#
.SYNOPSIS
    Enables Windows 11 Location Services and logs execution data to NinjaOne RMM.
.DESCRIPTION
    Removes HKLM registry restrictions, updates CapabilityAccessManager consent, 
    triggers the admin UI flow tool, and sets the Geolocation Service to automatic.
.PARAMETER NinjaCustomField
    Optional. The text name of a NinjaOne Custom Field to write the final status to (e.g., "locationServicesStatus").
#>



# Helper function to format logs cleanly for the NinjaOne Dashboard activity log
function Write-NinjaLog {
    param (
        [Parameter(Mandatory=$true)] [string]$Message,
        [Parameter(Mandatory=$false)] [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")] [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "ERROR"   { Write-Error "[$Timestamp] [ERROR] $Message"; break }
        "WARN"    { Write-Warning "[$Timestamp] [WARN] $Message"; break }
        "SUCCESS" { Write-Host "[$Timestamp] [SUCCESS] $Message" -ForegroundColor Green; break }
        Default   { Write-Host "[$Timestamp] [INFO] $Message" -ForegroundColor Cyan; break }
    }
}

Write-NinjaLog "Starting execution: Enable Windows 11 Location Services." "INFO"

# Ensure script is running with elevated privileges
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-NinjaLog "Script must be executed with Administrative/SYSTEM privileges. Exiting." "ERROR"
    exit 1 # Non-zero exit code flags failure in NinjaOne
}

try {
    # 1. Clear Group Policy restrictions
    $LocationSensorsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"
    $AppPrivacyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"

    if (Test-Path $LocationSensorsPath) {
        Remove-ItemProperty -Path $LocationSensorsPath -Name "DisableLocation" -ErrorAction SilentlyContinue
        Write-NinjaLog "Cleared LocationSensors policy restriction." "INFO"
    }
    if (Test-Path $AppPrivacyPath) {
        Remove-ItemProperty -Path $AppPrivacyPath -Name "LetAppsAccessLocation" -ErrorAction SilentlyContinue
        Write-NinjaLog "Cleared AppPrivacy location policy restriction." "INFO"
    }

    # 2. Allow location access system-wide via CapabilityAccessManager
    $ConsentStorePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
    if (-not (Test-Path $ConsentStorePath)) {
        $Null = New-Item -Path $ConsentStorePath -Force
    }
    Set-ItemProperty -Path $ConsentStorePath -Name "Value" -Value "Allow" -Type String -Force
    Write-NinjaLog "Global CapabilityAccessManager set to 'Allow'." "INFO"

    # 3. Trigger the system admin flow tool to turn on the master toggle
    $AdminFlowPath = "$env:WINDIR\System32\SystemSettingsAdminFlows.exe"
    if (Test-Path $AdminFlowPath) {
        $Null = Start-Process $AdminFlowPath -ArgumentList "SetCamSystemGlobal location 1" -Wait -NoNewWindow
        Write-NinjaLog "Executed SystemSettingsAdminFlows wrapper to enable master toggle." "INFO"
    } else {
        Write-NinjaLog "SystemSettingsAdminFlows.exe missing. Skipping UI toggle simulation." "WARN"
    }

    # 4. Configure and restart the Geolocation Service (lfsvc)
    Set-Service -Name "Lfsvc" -StartupType Automatic
    Restart-Service -Name "Lfsvc" -Force -ErrorAction Stop
    Write-NinjaLog "Geolocation Service (lfsvc) configured to Automatic and restarted." "INFO"

    # Final success operations
    $StatusMessage = "Location services enabled successfully."
    Write-NinjaLog $StatusMessage "SUCCESS"

    # Write to NinjaOne custom field if provided as a script parameter
    if (-not [string]::IsNullOrEmpty($NinjaCustomField)) {
        Ninja-Property-Set $NinjaCustomField "Enabled"
        Write-NinjaLog "Updated NinjaOne Custom Field '$NinjaCustomField' to 'Enabled'." "INFO"
    }

    exit 0 # Zero signals a completely green execution to the RMM console

} catch {
    Write-NinjaLog "An error occurred while modifying system parameters: $($_.Exception.Message)" "ERROR"
    
    if (-not [string]::IsNullOrEmpty($NinjaCustomField)) {
        Ninja-Property-Set $NinjaCustomField "Failed"
    }
    
    exit 1 # Non-zero exit code triggers NinjaOne alert policy
}
