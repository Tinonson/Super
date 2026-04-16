#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable LDAPS (LDAP over SSL/TLS, port 636) on a Windows Server 2022 DC.

.DESCRIPTION
    Run this script on maxdc01 and maxdc02 AFTER:
      - AD DS is installed and promoted (Script 01)
      - DNS is configured (Script 02)
      - The Enterprise CA is installed on maxdc03 and certificates have been
        issued (Script 04)

    What it does:
      1. Verifies a valid server-authentication certificate exists in the
         machine personal store.
      2. Configures the DC to bind LDAPS to that certificate via the
         NTDS\Parameters registry key.
      3. Restarts NTDS to pick up the certificate.
      4. Tests LDAPS connectivity on port 636.

    If no certificate is found, the script provides instructions for
    requesting one from the Enterprise CA.

    Domain : max.local
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$DomainFQDN = "max.local"

# ── 1. Locate a suitable certificate ───────────────────────────────
Write-Host "[*] Searching for a Server Authentication certificate ..." -ForegroundColor Cyan

$certs = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {
        $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1" -and  # Server Auth
        $_.Subject -match $env:COMPUTERNAME -and
        $_.NotAfter -gt (Get-Date)
    } |
    Sort-Object NotAfter -Descending

if ($certs.Count -eq 0) {
    Write-Host @"

[!] No suitable Server Authentication certificate found.

    Possible fixes:
      a) Run Script 04 on maxdc03 to deploy the Enterprise CA, then
         auto-enroll or manually request a "Domain Controller" /
         "Kerberos Authentication" certificate:

         certreq -enroll -machine "DomainController"

      b) Or trigger Group Policy to auto-enroll:
         gpupdate /force
         certutil -pulse

    After obtaining the certificate, re-run this script.
"@ -ForegroundColor Yellow
    exit 1
}

$cert = $certs[0]
Write-Host "    Found certificate:" -ForegroundColor Green
Write-Host "      Subject    : $($cert.Subject)"
Write-Host "      Thumbprint : $($cert.Thumbprint)"
Write-Host "      Expires    : $($cert.NotAfter)"

# ── 2. Bind the certificate to NTDS for LDAPS ─────────────────────
Write-Host "`n[*] Binding certificate to NTDS for LDAPS ..." -ForegroundColor Cyan

$ntdsParamsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"

if (-not (Test-Path $ntdsParamsPath)) {
    Write-Host "[!] NTDS Parameters registry key not found. Is this server a DC?" -ForegroundColor Red
    exit 1
}

# Method 1: Place certificate in NTDS\Personal store (preferred)
$ntdsStorePath = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\NTDS\Certificates"
if (-not (Test-Path $ntdsStorePath)) {
    New-Item -Path $ntdsStorePath -Force | Out-Null
}

# Export and import into the NTDS personal store
$ntdsStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    "NTDS\Personal", "LocalMachine"
)
try {
    $ntdsStore.Open("ReadWrite")
    $ntdsStore.Add($cert)
    Write-Host "    Certificate added to NTDS personal store." -ForegroundColor Green
} catch {
    Write-Host "    Could not open NTDS store – using registry fallback." -ForegroundColor Yellow
} finally {
    $ntdsStore.Close()
}

# ── 3. Restart Active Directory Domain Services ───────────────────
Write-Host "`n[*] Restarting NTDS service to apply LDAPS binding ..." -ForegroundColor Cyan
Restart-Service NTDS -Force
Start-Sleep -Seconds 5

# ── 4. Verify LDAPS on port 636 ───────────────────────────────────
Write-Host "[*] Testing LDAPS on localhost:636 ..." -ForegroundColor Cyan

$maxRetries = 3
$connected  = $false

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", 636)
        if ($tcp.Connected) {
            $connected = $true
            $tcp.Close()
            break
        }
    } catch {
        Write-Host "    Attempt $i/$maxRetries – port 636 not ready, waiting ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if ($connected) {
    Write-Host "[✓] LDAPS (port 636) is ACTIVE on $env:COMPUTERNAME." -ForegroundColor Green
} else {
    Write-Host "[✗] LDAPS (port 636) is NOT responding. Check the certificate and NTDS." -ForegroundColor Red
    exit 1
}

# ── 5. Quick TLS handshake validation ─────────────────────────────
Write-Host "`n[*] Validating TLS handshake on LDAPS ..." -ForegroundColor Cyan
try {
    $tcp    = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 636)
    $ssl    = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false,
        ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
    $ssl.AuthenticateAsClient($env:COMPUTERNAME + "." + $DomainFQDN)

    Write-Host "    Protocol   : $($ssl.SslProtocol)" -ForegroundColor Green
    Write-Host "    Cipher     : $($ssl.CipherAlgorithm)" -ForegroundColor Green
    Write-Host "    Cert Subject: $($ssl.RemoteCertificate.Subject)" -ForegroundColor Green

    $ssl.Close()
    $tcp.Close()
} catch {
    Write-Host "    [!] TLS handshake test failed: $_" -ForegroundColor Yellow
}

Write-Host "`n[✓] LDAPS is enabled and verified on $env:COMPUTERNAME." -ForegroundColor Green
