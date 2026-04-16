[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CAConfig,

    [Parameter(Mandatory = $true)]
    [string]$DomainFqdn,

    [Parameter(Mandatory = $true)]
    [string]$RoundRobinName,

    [string]$TemplateName = "WebServer",

    [switch]$RebootAfterEnrollment
)

$ErrorActionPreference = "Stop"

$fqdn = ("{0}.{1}" -f $env:COMPUTERNAME, $DomainFqdn).ToLowerInvariant()
$requestName = "ldaps-{0}" -f $env:COMPUTERNAME.ToLowerInvariant()
$workPath = Join-Path "C:\Lab" $requestName
$infPath = Join-Path $workPath "$requestName.inf"
$reqPath = Join-Path $workPath "$requestName.req"
$cerPath = Join-Path $workPath "$requestName.cer"

New-Item -ItemType Directory -Path $workPath -Force | Out-Null

$infText = @"
[Version]
Signature="\$Windows NT\$"

[NewRequest]
Subject = "CN=$fqdn"
FriendlyName = "LDAPS certificate for $fqdn"
MachineKeySet = TRUE
Exportable = TRUE
KeyLength = 2048
KeySpec = 1
KeyUsage = 0xa0
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
RequestType = PKCS10
SMIME = FALSE
HashAlgorithm = SHA256

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "dns=$fqdn&"
_continue_ = "dns=$RoundRobinName"

[RequestAttributes]
CertificateTemplate = $TemplateName
"@

Set-Content -Path $infPath -Value $infText -Encoding Ascii

Write-Host "Creating certificate request for $fqdn..."
certreq -new $infPath $reqPath | Out-Host

Write-Host "Submitting request to CA $CAConfig using template $TemplateName..."
certreq -submit -config $CAConfig -attrib "CertificateTemplate:$TemplateName" $reqPath $cerPath | Out-Host

Write-Host "Accepting issued certificate into LocalMachine\\My..."
certreq -accept $cerPath | Out-Host

$certificate = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {
        $_.Subject -eq "CN=$fqdn" -and
        ($_.EnhancedKeyUsageList | Where-Object FriendlyName -eq "Server Authentication")
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $certificate) {
    throw "No matching Server Authentication certificate was found in LocalMachine\My for $fqdn."
}

Write-Host ""
Write-Host "Installed LDAPS certificate"
$certificate | Select-Object Subject, Thumbprint, NotBefore, NotAfter, DnsNameList

if ($RebootAfterEnrollment.IsPresent) {
    Write-Host "Rebooting so AD DS immediately reloads the new LDAPS certificate..."
    Restart-Computer -Force
}
else {
    Write-Host "A reboot is recommended so AD DS immediately reloads the new LDAPS certificate."
}
