[CmdletBinding()]
param(
    [string]$CACommonName = "MAXLAB-ROOT-CA",
    [int]$ValidityYears = 10,
    [string]$OutputPath = "C:\Lab"
)

$ErrorActionPreference = "Stop"

Write-Host "Installing AD CS Certification Authority role on $env:COMPUTERNAME..."
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null

Write-Host "Configuring Enterprise Root CA $CACommonName..."
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCA `
    -CACommonName $CACommonName `
    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
    -HashAlgorithmName SHA256 `
    -KeyLength 4096 `
    -ValidityPeriod Years `
    -ValidityPeriodUnits $ValidityYears `
    -Force:$true

Import-Module ADCSAdministration

if (-not (Get-CATemplate | Where-Object Name -eq "WebServer")) {
    Write-Host "Publishing WebServer certificate template..."
    Add-CATemplate -Name "WebServer"
}

Restart-Service -Name CertSvc

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "Exporting CA certificate to $OutputPath\$CACommonName.cer..."
certutil -ca.cert "$OutputPath\$CACommonName.cer" | Out-Host

Write-Host ""
Write-Host "Published templates"
Get-CATemplate | Sort-Object Name | Select-Object Name
