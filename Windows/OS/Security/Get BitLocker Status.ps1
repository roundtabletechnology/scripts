<#
.SYNOPSIS
    Reports BitLocker encryption status for the system drive and publishes it to a Ninja RMM custom field.

.DESCRIPTION
    Queries Get-BitLockerVolume for the system drive and writes "BitLocker <VolumeStatus>"
    (e.g. "BitLocker FullyEncrypted", "BitLocker FullyDecrypted") to the Ninja RMM custom
    field "diskEncryptionStatus".

.NOTES
    Requires:
    - PowerShell 5.1 or later
    - Administrative privileges
    - Ninja RMM agent installed
#>

# Requires -RunAsAdministrator

param()

# Configuration
$NinjaCustomFieldName = "diskEncryptionStatus"
$SystemDrive = $env:SystemDrive

try {
    if (-not (Get-Module -ListAvailable -Name BitLocker)) {
        Write-Host "BitLocker module is not available on this system."
        Ninja-Property-Set $NinjaCustomFieldName "BitLocker Not Available"
        exit 0
    }
    Import-Module BitLocker -DisableNameChecking

    $bitlockerVolume = Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop

    $statusValue = "BitLocker $($bitlockerVolume.VolumeStatus)"
    Write-Host "Drive $SystemDrive - Volume Status: $($bitlockerVolume.VolumeStatus), Protection Status: $($bitlockerVolume.ProtectionStatus)"

    Ninja-Property-Set $NinjaCustomFieldName $statusValue
    Write-Host "Published '$statusValue' to Ninja RMM custom field: $NinjaCustomFieldName"
}
catch {
    Write-Error "Error retrieving BitLocker status: $_"
    Ninja-Property-Set $NinjaCustomFieldName "Error: $($_.Exception.Message)"
    exit 1
}
