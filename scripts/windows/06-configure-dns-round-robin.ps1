[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ZoneName,

    [string]$RecordName = "ldaps",

    [string[]]$IPv4Addresses = @("192.168.61.161", "192.168.61.162"),

    [int]$TtlSeconds = 30
)

$ErrorActionPreference = "Stop"
$ttl = New-TimeSpan -Seconds $TtlSeconds
$fqdn = "{0}.{1}" -f $RecordName, $ZoneName

Write-Host "Enabling DNS round-robin on $env:COMPUTERNAME..."
Set-DnsServerSetting -EnableRoundRobin $true -LocalNetPriority $false

$existingRecords = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $RecordName -RRType A -ErrorAction SilentlyContinue

foreach ($address in $IPv4Addresses) {
    $alreadyExists = $existingRecords | Where-Object {
        $_.RecordData.IPv4Address.IPAddressToString -eq $address
    }

    if (-not $alreadyExists) {
        Write-Host "Adding $fqdn -> $address"
        Add-DnsServerResourceRecordA `
            -ZoneName $ZoneName `
            -Name $RecordName `
            -IPv4Address $address `
            -TimeToLive $ttl | Out-Null
    }
}

Write-Host ""
Write-Host "Current A records for $fqdn"
Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $RecordName -RRType A |
    Select-Object HostName, @{Name = "IPAddress"; Expression = { $_.RecordData.IPv4Address.IPAddressToString } }, TimeToLive

Write-Host ""
Write-Host "Sample DNS answers"
1..6 | ForEach-Object {
    Clear-DnsClientCache
    $answers = Resolve-DnsName -Name $fqdn -Type A | Select-Object -ExpandProperty IPAddress
    [pscustomobject]@{
        Attempt = $_
        Answers = $answers -join ", "
    }
    Start-Sleep -Seconds 1
}
