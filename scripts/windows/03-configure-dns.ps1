[CmdletBinding()]
param(
    [string[]]$Forwarders = @("1.1.1.1", "8.8.8.8")
)

$ErrorActionPreference = "Stop"

Write-Host "Ensuring DNS role is installed on $env:COMPUTERNAME..."
Install-WindowsFeature DNS -IncludeManagementTools | Out-Null

Set-Service -Name DNS -StartupType Automatic
if ((Get-Service -Name DNS).Status -ne "Running") {
    Start-Service -Name DNS
}

if ($Forwarders.Count -gt 0) {
    Write-Host "Configuring forwarders: $($Forwarders -join ', ')"
    Set-DnsServerForwarder -IPAddress $Forwarders | Out-Null
}

Write-Host "Enabling DNS round-robin and disabling local net priority..."
Set-DnsServerSetting -EnableRoundRobin $true -LocalNetPriority $false

Write-Host ""
Write-Host "DNS service summary"
Get-DnsServerSetting | Select-Object EnableRoundRobin, LocalNetPriority

Write-Host ""
Write-Host "DNS forwarders"
Get-DnsServerForwarder

Write-Host ""
Write-Host "DNS zones"
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone
