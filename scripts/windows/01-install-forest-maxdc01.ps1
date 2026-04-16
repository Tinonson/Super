[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [string]$NetBIOSName,

    [Parameter(Mandatory = $true)]
    [SecureString]$SafeModeAdministratorPassword
)

$ErrorActionPreference = "Stop"

Write-Host "Installing AD DS and DNS roles on $env:COMPUTERNAME..."
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null

Write-Host "Creating new forest $DomainName on $env:COMPUTERNAME..."
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBIOSName `
    -InstallDNS `
    -CreateDnsDelegation:$false `
    -SafeModeAdministratorPassword $SafeModeAdministratorPassword `
    -NoRebootOnCompletion:$false `
    -Force:$true
