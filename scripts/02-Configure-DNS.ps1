#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure DNS on each domain controller after AD DS promotion.

.DESCRIPTION
    Run this script on EVERY DC (maxdc01, maxdc02, maxdc03) after all three
    have been promoted and rebooted.

    What it does:
      1. Verifies the DNS Server role is running.
      2. Creates a forward-lookup zone for the domain (if missing).
      3. Creates a reverse-lookup zone for 192.168.61.0/24 (if missing).
      4. Registers A and PTR records for every DC.
      5. Configures each server's NIC to point to all three DCs for DNS.
      6. Forces AD-integrated zone replication.

    Servers:
      maxdc01  192.168.61.161
      maxdc02  192.168.61.162
      maxdc03  192.168.61.163

    Domain : max.local
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Lab-wide variables ──────────────────────────────────────────────
$DomainName   = "max.local"
$ReverseZone  = "61.168.192.in-addr.arpa"
$SubnetPrefix = "192.168.61"

$DCs = @(
    @{ Name = "maxdc01"; IP = "192.168.61.161" },
    @{ Name = "maxdc02"; IP = "192.168.61.162" },
    @{ Name = "maxdc03"; IP = "192.168.61.163" }
)

# ── 1. Verify DNS Server role ──────────────────────────────────────
Write-Host "[*] Verifying DNS Server role is installed ..." -ForegroundColor Cyan
$dnsFeat = Get-WindowsFeature -Name DNS
if (-not $dnsFeat.Installed) {
    Write-Host "[*] DNS Server not installed – installing now ..." -ForegroundColor Yellow
    Install-WindowsFeature -Name DNS -IncludeManagementTools
}

Import-Module DnsServer

# ── 2. Forward-lookup zone ──────────────────────────────────────────
Write-Host "[*] Checking forward-lookup zone '$DomainName' ..." -ForegroundColor Cyan
$fwdZone = Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue
if (-not $fwdZone) {
    Write-Host "[+] Creating AD-integrated forward-lookup zone '$DomainName' ..." -ForegroundColor Green
    Add-DnsServerPrimaryZone -Name $DomainName `
        -ReplicationScope "Forest" `
        -DynamicUpdate "Secure"
} else {
    Write-Host "    Zone '$DomainName' already exists." -ForegroundColor DarkGray
}

# ── 3. Reverse-lookup zone ──────────────────────────────────────────
Write-Host "[*] Checking reverse-lookup zone '$ReverseZone' ..." -ForegroundColor Cyan
$revZone = Get-DnsServerZone -Name $ReverseZone -ErrorAction SilentlyContinue
if (-not $revZone) {
    Write-Host "[+] Creating AD-integrated reverse-lookup zone ..." -ForegroundColor Green
    Add-DnsServerPrimaryZone -NetworkId "${SubnetPrefix}.0/24" `
        -ReplicationScope "Forest" `
        -DynamicUpdate "Secure"
} else {
    Write-Host "    Reverse zone already exists." -ForegroundColor DarkGray
}

# ── 4. Register A + PTR records for every DC ───────────────────────
foreach ($dc in $DCs) {
    $fqdn    = "$($dc.Name).$DomainName"
    $lastOct = ($dc.IP -split "\.")[-1]

    # A record
    $existing = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $dc.Name `
        -RRType A -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "[+] Adding A record: $fqdn -> $($dc.IP)" -ForegroundColor Green
        Add-DnsServerResourceRecordA -ZoneName $DomainName `
            -Name $dc.Name -IPv4Address $dc.IP -CreatePtr
    } else {
        Write-Host "    A record for $fqdn already exists." -ForegroundColor DarkGray
    }

    # PTR record (explicit, in case -CreatePtr was skipped)
    $ptrName = $lastOct
    $ptrExist = Get-DnsServerResourceRecord -ZoneName $ReverseZone -Name $ptrName `
        -RRType Ptr -ErrorAction SilentlyContinue
    if (-not $ptrExist) {
        Write-Host "[+] Adding PTR record: $lastOct -> $fqdn" -ForegroundColor Green
        Add-DnsServerResourceRecordPtr -ZoneName $ReverseZone `
            -Name $ptrName -PtrDomainName $fqdn
    } else {
        Write-Host "    PTR record for $lastOct already exists." -ForegroundColor DarkGray
    }
}

# ── 5. Point this server's NIC to all three DCs for DNS ────────────
Write-Host "[*] Configuring DNS client settings on $env:COMPUTERNAME ..." -ForegroundColor Cyan

$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
$dnsServers = $DCs | ForEach-Object { $_.IP }

Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
    -ServerAddresses $dnsServers

Write-Host "    DNS servers set to: $($dnsServers -join ', ')" -ForegroundColor DarkGray

# ── 6. Force replication ───────────────────────────────────────────
Write-Host "[*] Forcing AD replication ..." -ForegroundColor Cyan
repadmin /syncall /AdeP 2>&1 | Out-Null

# ── 7. Verify ──────────────────────────────────────────────────────
Write-Host "`n[*] DNS verification:" -ForegroundColor Cyan
foreach ($dc in $DCs) {
    $result = Resolve-DnsName -Name "$($dc.Name).$DomainName" -Type A -ErrorAction SilentlyContinue
    if ($result) {
        Write-Host "    [✓] $($dc.Name).$DomainName -> $($result.IPAddress)" -ForegroundColor Green
    } else {
        Write-Host "    [✗] $($dc.Name).$DomainName FAILED to resolve" -ForegroundColor Red
    }
}

Write-Host "`n[✓] DNS configuration complete on $env:COMPUTERNAME." -ForegroundColor Green
