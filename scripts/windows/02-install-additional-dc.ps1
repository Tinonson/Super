[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [pscredential]$DomainCredential,

    [Parameter(Mandatory = $true)]
    [SecureString]$SafeModeAdministratorPassword,

    [string]$SiteName = "Default-First-Site-Name"
)

$ErrorActionPreference = "Stop"

Write-Host "Installing AD DS and DNS roles on $env:COMPUTERNAME..."
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null

Write-Host "Promoting $env:COMPUTERNAME to a domain controller in $DomainName..."
Install-ADDSDomainController `
    -DomainName $DomainName `
    -Credential $DomainCredential `
    -InstallDNS `
    -CreateDnsDelegation:$false `
    -SiteName $SiteName `
    -SafeModeAdministratorPassword $SafeModeAdministratorPassword `
    -NoRebootOnCompletion:$false `
    -Force:$true
