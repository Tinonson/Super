#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install Enterprise CA on maxdc03 and generate certificates for LDAPS.

.DESCRIPTION
    Run this script on maxdc03 ONLY, AFTER:
      - All three DCs have been promoted (Script 01)
      - DNS is configured (Script 02)

    What it does:
      Part A – Install and configure the Enterprise Root CA on maxdc03.
      Part B – Create/update a certificate template for Domain Controllers
               that supports Server Authentication (required for LDAPS).
      Part C – Issue certificates to maxdc01 and maxdc02 via auto-enrollment
               or manual request.

    Domain  : max.local
    CA Name : MAX-ROOT-CA
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$DomainName = "max.local"
$CAName     = "MAX-ROOT-CA"

# ═══════════════════════════════════════════════════════════════════
#  PART A: Install the Certification Authority role
# ═══════════════════════════════════════════════════════════════════
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PART A: Installing Active Directory Certificate Services" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

# A1. Install the AD CS role with the CA and Web Enrollment features
Write-Host "`n[*] Installing AD CS role ..." -ForegroundColor Cyan
Install-WindowsFeature -Name ADCS-Cert-Authority, ADCS-Web-Enrollment `
    -IncludeManagementTools -Verbose

# A2. Configure as Enterprise Root CA
Write-Host "`n[*] Configuring Enterprise Root CA ('$CAName') ..." -ForegroundColor Cyan
try {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CACommonName $CAName `
        -KeyLength 4096 `
        -HashAlgorithmName SHA256 `
        -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
        -ValidityPeriod Years `
        -ValidityPeriodUnits 10 `
        -Force
    Write-Host "    CA installed successfully." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already installed|already configured") {
        Write-Host "    CA is already configured – skipping." -ForegroundColor Yellow
    } else {
        throw
    }
}

# A3. Configure Web Enrollment
Write-Host "`n[*] Configuring Certificate Authority Web Enrollment ..." -ForegroundColor Cyan
try {
    Install-AdcsWebEnrollment -Force
    Write-Host "    Web Enrollment configured." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already installed|already configured") {
        Write-Host "    Web Enrollment already configured – skipping." -ForegroundColor Yellow
    } else {
        Write-Host "    [!] Web Enrollment config warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ═══════════════════════════════════════════════════════════════════
#  PART B: Configure certificate template for LDAPS
# ═══════════════════════════════════════════════════════════════════
Write-Host "`n═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PART B: Configuring Certificate Template for LDAPS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

Import-Module ActiveDirectory

# B1. Duplicate the built-in "Kerberos Authentication" template for LDAPS use
$templateName = "LDAPSCertificate"
$templateDisplayName = "LDAPS Certificate"
$configDN = (Get-ADRootDSE).configurationNamingContext
$templatesDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configDN"

$existingTemplate = Get-ADObject -Filter "cn -eq '$templateName'" `
    -SearchBase $templatesDN -ErrorAction SilentlyContinue

if ($existingTemplate) {
    Write-Host "    Template '$templateDisplayName' already exists – skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "[*] Creating certificate template '$templateDisplayName' ..." -ForegroundColor Green

    # Use the Kerberos Authentication template as a source
    $sourceTemplate = Get-ADObject -Filter "displayName -eq 'Kerberos Authentication'" `
        -SearchBase $templatesDN -Properties *

    if (-not $sourceTemplate) {
        Write-Host "    [!] 'Kerberos Authentication' template not found." -ForegroundColor Yellow
        Write-Host "    [*] Falling back to enabling the default 'Domain Controller' template." -ForegroundColor Cyan
        $templateName = "DomainController"
    } else {
        $newOID = [System.Guid]::NewGuid().ToString()
        $templateAttrs = @{
            "displayName"               = $templateDisplayName
            "msPKI-Cert-Template-OID"   = "1.3.6.1.4.1.311.21.8.$newOID"
            "flags"                      = 131680
            "revision"                   = 100
            "pKIDefaultKeySpec"          = 1
            "pKIMaxIssuingDepth"         = 0
            "pKIDefaultCSPs"             = "1,Microsoft RSA SChannel Cryptographic Provider"
            "msPKI-RA-Signature"         = 0
            "msPKI-Enrollment-Flag"      = 0
            "msPKI-Private-Key-Flag"     = 16842752
            "msPKI-Certificate-Name-Flag" = 134217728
            "msPKI-Minimal-Key-Size"     = 2048
            "pKIExtendedKeyUsage"        = @("1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2")
            "pKICriticalExtensions"      = @("2.5.29.15")
            "pKIExpirationPeriod"        = $sourceTemplate.'pKIExpirationPeriod'
            "pKIOverlapPeriod"           = $sourceTemplate.'pKIOverlapPeriod'
        }

        New-ADObject -Name $templateName `
            -Type "pKICertificateTemplate" `
            -Path $templatesDN `
            -OtherAttributes $templateAttrs

        # Grant Enroll permission to Domain Controllers
        $dcGroup = Get-ADGroup "Domain Controllers"
        $templateObj = Get-ADObject "CN=$templateName,$templatesDN"
        $acl = Get-Acl "AD:\$($templateObj.DistinguishedName)"
        $enrollGuid = [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $dcGroup.SID, "ExtendedRight", "Allow", $enrollGuid
        )
        $acl.AddAccessRule($ace)
        Set-Acl "AD:\$($templateObj.DistinguishedName)" $acl

        Write-Host "    Template '$templateDisplayName' created and permissions set." -ForegroundColor Green
    }
}

# B2. Publish the template to the CA
Write-Host "`n[*] Publishing template '$templateName' to the CA ..." -ForegroundColor Cyan
$caEnrollDN = "CN=$CAName,CN=Enrollment Services,CN=Public Key Services,CN=Services,$configDN"

try {
    $enrollObj = Get-ADObject $caEnrollDN -Properties certificateTemplates
    if ($enrollObj.certificateTemplates -notcontains $templateName) {
        Set-ADObject $caEnrollDN -Add @{ certificateTemplates = $templateName }
        Write-Host "    Template published." -ForegroundColor Green
    } else {
        Write-Host "    Template already published." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "    [!] Could not publish template: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "    [*] Manually publish via certsrv.msc > Certificate Templates > New > Template to Issue" -ForegroundColor Yellow
}

# Also ensure the built-in "Kerberos Authentication" template is published
try {
    $enrollObj = Get-ADObject $caEnrollDN -Properties certificateTemplates
    if ($enrollObj.certificateTemplates -notcontains "KerberosAuthentication") {
        Set-ADObject $caEnrollDN -Add @{ certificateTemplates = "KerberosAuthentication" }
        Write-Host "    'Kerberos Authentication' template also published." -ForegroundColor Green
    }
} catch {
    Write-Host "    [!] Note: Could not publish KerberosAuthentication template." -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════════
#  PART C: Trigger certificate enrollment on Domain Controllers
# ═══════════════════════════════════════════════════════════════════
Write-Host "`n═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PART C: Triggering Certificate Enrollment" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

# C1. Force Group Policy update to trigger auto-enrollment on this DC
Write-Host "`n[*] Forcing Group Policy update on $env:COMPUTERNAME ..." -ForegroundColor Cyan
gpupdate /force 2>&1 | Out-Null

# C2. Trigger certificate auto-enrollment
Write-Host "[*] Triggering certificate auto-enrollment ..." -ForegroundColor Cyan
certutil -pulse 2>&1 | Out-Null

Write-Host @"

[✓] CA installation and template configuration complete on $env:COMPUTERNAME.

    NEXT STEPS:
    ───────────────────────────────────────────────────────────────
    On maxdc01 and maxdc02, run these commands to request certificates:

      # Option A: Auto-enroll via Group Policy
      gpupdate /force
      certutil -pulse

      # Option B: Manual enrollment
      certreq -enroll -machine "KerberosAuthentication"
        -- OR --
      certreq -enroll -machine "$templateDisplayName"

    After certificates appear in Cert:\LocalMachine\My, run:
      .\03-Enable-LDAPs.ps1

    To verify certificates on any DC:
      Get-ChildItem Cert:\LocalMachine\My | Format-List Subject, Thumbprint, NotAfter

"@ -ForegroundColor Green
