#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install Active Directory Domain Services and promote domain controllers.

.DESCRIPTION
    Run this script in order:
      Step A  – on maxdc01 (first DC, creates the forest)
      Step B  – on maxdc02 and maxdc03 (additional DCs, join existing domain)

    Domain : max.local
    Forest functional level : Windows Server 2016 (highest for 2022)

.PARAMETER Role
    "FirstDC" or "AdditionalDC"

.EXAMPLE
    # On maxdc01 (first domain controller – creates the forest):
    .\01-Install-ADDS-Role.ps1 -Role FirstDC

    # On maxdc02 and maxdc03 (join existing domain):
    .\01-Install-ADDS-Role.ps1 -Role AdditionalDC
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("FirstDC", "AdditionalDC")]
    [string]$Role
)

$ErrorActionPreference = "Stop"

# ── Lab-wide variables ──────────────────────────────────────────────
$DomainName        = "max.local"
$DomainNetBIOSName = "MAX"
$ForestMode        = "WinThreshold"   # Windows Server 2016 functional level
$DomainMode        = "WinThreshold"
$SafeModePW        = ConvertTo-SecureString "P@ssw0rd!2025" -AsPlainText -Force

# ── Step 1: Install the AD DS role and management tools ─────────────
Write-Host "[*] Installing AD DS role and management tools ..." -ForegroundColor Cyan
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -Verbose

# ── Step 2: Promote to domain controller ────────────────────────────
Import-Module ADDSDeployment

switch ($Role) {

    "FirstDC" {
        Write-Host "[*] Promoting $env:COMPUTERNAME as the FIRST DC – creating forest '$DomainName' ..." -ForegroundColor Green

        Install-ADDSForest `
            -DomainName              $DomainName `
            -DomainNetBIOSName       $DomainNetBIOSName `
            -ForestMode              $ForestMode `
            -DomainMode              $DomainMode `
            -InstallDns              `
            -CreateDnsDelegation:$false `
            -SafeModeAdministratorPassword $SafeModePW `
            -DatabasePath            "C:\Windows\NTDS" `
            -LogPath                 "C:\Windows\NTDS" `
            -SysvolPath              "C:\Windows\SYSVOL" `
            -NoRebootOnCompletion:$false `
            -Force:$true
    }

    "AdditionalDC" {
        Write-Host "[*] Promoting $env:COMPUTERNAME as an ADDITIONAL DC in '$DomainName' ..." -ForegroundColor Green
        Write-Host "[*] You will be prompted for domain admin credentials." -ForegroundColor Yellow

        $Cred = Get-Credential -Message "Enter MAX\Administrator (or domain admin) credentials"

        Install-ADDSDomainController `
            -DomainName              $DomainName `
            -InstallDns              `
            -Credential              $Cred `
            -SafeModeAdministratorPassword $SafeModePW `
            -DatabasePath            "C:\Windows\NTDS" `
            -LogPath                 "C:\Windows\NTDS" `
            -SysvolPath              "C:\Windows\SYSVOL" `
            -NoRebootOnCompletion:$false `
            -Force:$true
    }
}

Write-Host "`n[✓] AD DS promotion complete. The server will reboot automatically." -ForegroundColor Green
