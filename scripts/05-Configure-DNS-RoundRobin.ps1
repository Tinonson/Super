#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure DNS round-robin for LDAPS high availability.

.DESCRIPTION
    Run this script on ANY DC (preferably maxdc01 or maxdc03) AFTER:
      - All DCs are promoted and DNS is configured (Scripts 01-02)
      - LDAPS is enabled on maxdc01 and maxdc02 (Scripts 03-04)

    What it does:
      1. Creates a DNS A record "ldaps.max.local" pointing to maxdc01 (192.168.61.161).
      2. Creates a second DNS A record "ldaps.max.local" pointing to maxdc02 (192.168.61.162).
      3. Enables DNS round-robin on the DNS server (on by default, but we
         ensure it explicitly).
      4. Disables netmask ordering so round-robin takes effect for all clients.
      5. Verifies the round-robin response.

    The hostname "ldaps.max.local" is used by clients to connect to LDAPS.
    DNS will alternate between the two DCs for high availability.

    Domain : max.local
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$DomainName  = "max.local"
$LdapsHost   = "ldaps"                # ldaps.max.local
$LdapsFQDN   = "$LdapsHost.$DomainName"

$LdapsDCs = @(
    @{ Name = "maxdc01"; IP = "192.168.61.161" },
    @{ Name = "maxdc02"; IP = "192.168.61.162" }
)

Import-Module DnsServer

# ── 1. Enable DNS Round-Robin ──────────────────────────────────────
Write-Host "[*] Ensuring DNS round-robin is enabled ..." -ForegroundColor Cyan

Set-DnsServerSetting -RoundRobin $true
Write-Host "    Round-robin: ENABLED" -ForegroundColor Green

# Disable netmask ordering so round-robin actually rotates for all subnets
$serverSetting = Get-DnsServerSetting -All
if ($serverSetting.LocalNetPriority) {
    Write-Host "[*] Disabling LocalNetPriority (netmask ordering) ..." -ForegroundColor Cyan
    $serverSetting.LocalNetPriority = $false
    Set-DnsServerSetting -InputObject $serverSetting
    Write-Host "    LocalNetPriority: DISABLED" -ForegroundColor Green
} else {
    Write-Host "    LocalNetPriority already disabled." -ForegroundColor DarkGray
}

# ── 2. Create round-robin A records for ldaps.max.local ────────────
Write-Host "`n[*] Creating round-robin A records for '$LdapsFQDN' ..." -ForegroundColor Cyan

foreach ($dc in $LdapsDCs) {
    $existing = Get-DnsServerResourceRecord -ZoneName $DomainName -Name $LdapsHost `
        -RRType A -ErrorAction SilentlyContinue |
        Where-Object { $_.RecordData.IPv4Address.ToString() -eq $dc.IP }

    if ($existing) {
        Write-Host "    A record $LdapsFQDN -> $($dc.IP) already exists." -ForegroundColor DarkGray
    } else {
        Add-DnsServerResourceRecordA -ZoneName $DomainName `
            -Name $LdapsHost `
            -IPv4Address $dc.IP `
            -TimeToLive (New-TimeSpan -Minutes 5)

        Write-Host "    [+] Added A record: $LdapsFQDN -> $($dc.IP) (TTL 5m)" -ForegroundColor Green
    }
}

# ── 3. Force DNS zone replication ─────────────────────────────────
Write-Host "`n[*] Forcing DNS zone replication ..." -ForegroundColor Cyan
repadmin /syncall /AdeP 2>&1 | Out-Null
Start-Sleep -Seconds 3

# ── 4. Verify round-robin resolution ──────────────────────────────
Write-Host "`n[*] Verifying DNS round-robin for '$LdapsFQDN' ..." -ForegroundColor Cyan

$results = Resolve-DnsName -Name $LdapsFQDN -Type A -ErrorAction SilentlyContinue
if ($results) {
    Write-Host "    Resolved addresses:" -ForegroundColor Green
    foreach ($r in $results) {
        Write-Host "      $LdapsFQDN -> $($r.IPAddress)" -ForegroundColor Green
    }

    $ips = $results | ForEach-Object { $_.IPAddress }
    $expected = $LdapsDCs | ForEach-Object { $_.IP }
    $missing = $expected | Where-Object { $_ -notin $ips }

    if ($missing) {
        Write-Host "    [!] Missing IPs in round-robin: $($missing -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "    [✓] Both DCs are in the round-robin pool." -ForegroundColor Green
    }
} else {
    Write-Host "    [✗] DNS resolution failed for $LdapsFQDN" -ForegroundColor Red
}

# ── 5. Test LDAPS connectivity to both DCs ─────────────────────────
Write-Host "`n[*] Testing LDAPS connectivity ..." -ForegroundColor Cyan

foreach ($dc in $LdapsDCs) {
    Write-Host "    Testing $($dc.Name) ($($dc.IP)):636 ..." -NoNewline
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($dc.IP, 636)
        if ($tcp.Connected) {
            Write-Host " [✓] CONNECTED" -ForegroundColor Green
            $tcp.Close()
        }
    } catch {
        Write-Host " [✗] FAILED" -ForegroundColor Red
    }
}

# ── 6. Test round-robin by querying multiple times ─────────────────
Write-Host "`n[*] Round-robin rotation test (5 queries) ..." -ForegroundColor Cyan

for ($i = 1; $i -le 5; $i++) {
    $res = Resolve-DnsName -Name $LdapsFQDN -Type A -DnsOnly -ErrorAction SilentlyContinue
    $firstIP = $res[0].IPAddress
    Write-Host "    Query $i : first answer = $firstIP"
}

Write-Host @"

[✓] DNS round-robin configuration complete.

    Summary:
    ──────────────────────────────────────────────
    Hostname : $LdapsFQDN
    DC Pool  : $($LdapsDCs[0].IP) ($($LdapsDCs[0].Name))
               $($LdapsDCs[1].IP) ($($LdapsDCs[1].Name))
    TTL      : 5 minutes
    Method   : DNS round-robin (LocalNetPriority disabled)

    Clients should connect to:
      ldaps://${LdapsFQDN}:636

"@ -ForegroundColor Green
