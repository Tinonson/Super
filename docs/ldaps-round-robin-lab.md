# LDAPS with DNS round-robin on Windows Server 2022

## 1. Lab goal

Build a three-server Windows Server 2022 lab that provides:

- Active Directory Domain Services on all three servers
- DNS on all three domain controllers
- Active Directory Certificate Services on `maxdc03`
- LDAPS on the domain controllers
- A shared DNS name that round-robins between `maxdc01` and `maxdc02`
- Ubuntu client testing for TLS validation, LDAP bind, and failover behavior

## 2. Lab topology

| Hostname | IP address | Planned role |
| --- | --- | --- |
| maxdc01 | 192.168.61.161 | Forest root DC, DNS, LDAPS target |
| maxdc02 | 192.168.61.162 | Additional DC, DNS, LDAPS target |
| maxdc03 | 192.168.61.163 | Additional DC, DNS, Enterprise Root CA |

Recommended shared LDAPS name:

- `ldaps.lab.example.com`

Replace `lab.example.com` with your real AD DNS name before you run the scripts.

## 3. Important limitations and design notes

1. DNS round-robin is not true health-aware high availability.
   - A failed server can still be returned until record TTL expires or the client retries.
   - If you need strict health checks and immediate failout, use a load balancer instead of DNS round-robin.
2. LDAPS certificate validation requires hostname matching.
   - If clients connect to `ldaps.lab.example.com`, then the certificates on `maxdc01` and `maxdc02` must include that shared alias in SAN.
   - The certificate enrollment script in this repo requests a CA-issued certificate with both the DC FQDN and the shared alias.
3. Run all Windows scripts from an elevated PowerShell session.
4. Use static IP addressing on all servers before promotion.

## 4. Recommended build order

### Step 1: Create the forest on `maxdc01`

Run:

- `scripts/windows/01-install-forest-maxdc01.ps1`

Example:

```powershell
$dsrmPassword = Read-Host "Enter DSRM password" -AsSecureString

.\scripts\windows\01-install-forest-maxdc01.ps1 `
  -DomainName "lab.example.com" `
  -NetBIOSName "LAB" `
  -SafeModeAdministratorPassword $dsrmPassword
```

After the reboot, log on with the domain admin account.

### Step 2: Promote `maxdc02` and `maxdc03`

Run on both `maxdc02` and `maxdc03`:

- `scripts/windows/02-install-additional-dc.ps1`

Example:

```powershell
$domainCred = Get-Credential "LAB\Administrator"
$dsrmPassword = Read-Host "Enter DSRM password" -AsSecureString

.\scripts\windows\02-install-additional-dc.ps1 `
  -DomainName "lab.example.com" `
  -DomainCredential $domainCred `
  -SafeModeAdministratorPassword $dsrmPassword
```

### Step 3: Configure DNS service settings on each DC

Run on `maxdc01`, `maxdc02`, and `maxdc03`:

- `scripts/windows/03-configure-dns.ps1`

Example:

```powershell
.\scripts\windows\03-configure-dns.ps1 -Forwarders @("1.1.1.1", "8.8.8.8")
```

This script:

- Ensures DNS is installed and running
- Sets DNS service to automatic startup
- Enables round-robin on the DNS server
- Disables local net priority so round-robin order is easier to observe in the lab

### Step 4: Install the CA on `maxdc03`

Run on `maxdc03`:

- `scripts/windows/04-install-enterprise-root-ca-maxdc03.ps1`

Example:

```powershell
.\scripts\windows\04-install-enterprise-root-ca-maxdc03.ps1 `
  -CACommonName "MAXLAB-ROOT-CA" `
  -ValidityYears 10 `
  -OutputPath "C:\Lab"
```

This script:

- Installs AD CS as an Enterprise Root CA
- Publishes the `WebServer` certificate template
- Exports the root CA certificate for the Ubuntu client

Expected output file on `maxdc03`:

- `C:\Lab\MAXLAB-ROOT-CA.cer`

### Step 5: Request and install LDAPS certificates

Run on `maxdc01` and `maxdc02` so both servers can answer the shared LDAPS name:

- `scripts/windows/05-request-ldaps-certificate.ps1`

Example for `maxdc01`:

```powershell
.\scripts\windows\05-request-ldaps-certificate.ps1 `
  -CAConfig "maxdc03.lab.example.com\MAXLAB-ROOT-CA" `
  -DomainFqdn "lab.example.com" `
  -RoundRobinName "ldaps.lab.example.com" `
  -RebootAfterEnrollment
```

Example for `maxdc02`:

```powershell
.\scripts\windows\05-request-ldaps-certificate.ps1 `
  -CAConfig "maxdc03.lab.example.com\MAXLAB-ROOT-CA" `
  -DomainFqdn "lab.example.com" `
  -RoundRobinName "ldaps.lab.example.com" `
  -RebootAfterEnrollment
```

Optional direct LDAPS certificate for `maxdc03`:

```powershell
.\scripts\windows\05-request-ldaps-certificate.ps1 `
  -CAConfig "maxdc03.lab.example.com\MAXLAB-ROOT-CA" `
  -DomainFqdn "lab.example.com" `
  -RoundRobinName "maxdc03.lab.example.com"
```

Why the script uses a Web Server certificate:

- The built-in certificate only needs Server Authentication EKU plus the DC FQDN for AD DS to use it for LDAPS.
- The shared alias must also be in SAN so Ubuntu and other TLS clients can validate the shared round-robin name.

### Step 6: Configure the round-robin LDAPS DNS record

Run on one DNS server, for example `maxdc01`:

- `scripts/windows/06-configure-dns-round-robin.ps1`

Example:

```powershell
.\scripts\windows\06-configure-dns-round-robin.ps1 `
  -ZoneName "lab.example.com" `
  -RecordName "ldaps" `
  -IPv4Addresses @("192.168.61.161", "192.168.61.162") `
  -TtlSeconds 30
```

This creates:

- `ldaps.lab.example.com -> 192.168.61.161`
- `ldaps.lab.example.com -> 192.168.61.162`

### Step 7: Windows-side validation

Run:

- `scripts/windows/07-test-ldaps-windows.ps1`

Example:

```powershell
$ldapCred = Get-Credential "LAB\Administrator"

.\scripts\windows\07-test-ldaps-windows.ps1 `
  -LdapsName "ldaps.lab.example.com" `
  -Credential $ldapCred `
  -Rounds 6
```

What it checks:

- Repeated DNS resolution order
- TCP/636 reachability
- An LDAPS bind using .NET LDAP APIs

## 5. Ubuntu client testing

### 5.1 Install the client tools

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y ldap-utils openssl dnsutils
```

### 5.2 Copy the CA certificate from `maxdc03`

Copy `C:\Lab\MAXLAB-ROOT-CA.cer` from `maxdc03` to Ubuntu, then install it:

```bash
sudo cp MAXLAB-ROOT-CA.cer /usr/local/share/ca-certificates/MAXLAB-ROOT-CA.crt
sudo update-ca-certificates
```

### 5.3 Run the Ubuntu test script

Example:

```bash
chmod +x scripts/linux/01-test-ldaps-ubuntu.sh

LDAPS_HOST="ldaps.lab.example.com" \
DNS_SERVER="192.168.61.161" \
CA_CERT="/usr/local/share/ca-certificates/MAXLAB-ROOT-CA.crt" \
BIND_DN="CN=Administrator,CN=Users,DC=lab,DC=example,DC=com" \
BIND_PASSWORD='YourPasswordHere' \
BASE_DN="DC=lab,DC=example,DC=com" \
./scripts/linux/01-test-ldaps-ubuntu.sh
```

The script performs:

- Repeated DNS lookups to show answer rotation
- TLS handshake verification against the CA certificate
- LDAP RootDSE query over LDAPS

## 6. Failover test procedure

Use this to demonstrate how DNS round-robin behaves when one LDAPS node is unavailable.

### Option A: Temporarily block LDAPS on `maxdc01`

Run on `maxdc01`:

```powershell
New-NetFirewallRule `
  -DisplayName "Block LDAPS 636 For Test" `
  -Direction Inbound `
  -Action Block `
  -Protocol TCP `
  -LocalPort 636
```

Remove it after the test:

```powershell
Remove-NetFirewallRule -DisplayName "Block LDAPS 636 For Test"
```

### Option B: Stop the server or disconnect its NIC

This is a more obvious failover demonstration in an isolated lab.

### Expected result

- Some client attempts may still fail briefly if DNS returns the failed IP first.
- After client DNS refresh and retry, binds should succeed against the remaining LDAPS node.

That behavior is normal for DNS round-robin and is the main reason it should be treated as a simple distribution mechanism, not a health-checked VIP.

## 7. Quick command summary

### `maxdc01`

```powershell
$dsrmPassword = Read-Host "Enter DSRM password" -AsSecureString
.\scripts\windows\01-install-forest-maxdc01.ps1 -DomainName "lab.example.com" -NetBIOSName "LAB" -SafeModeAdministratorPassword $dsrmPassword
.\scripts\windows\03-configure-dns.ps1 -Forwarders @("1.1.1.1", "8.8.8.8")
.\scripts\windows\05-request-ldaps-certificate.ps1 -CAConfig "maxdc03.lab.example.com\MAXLAB-ROOT-CA" -DomainFqdn "lab.example.com" -RoundRobinName "ldaps.lab.example.com" -RebootAfterEnrollment
.\scripts\windows\06-configure-dns-round-robin.ps1 -ZoneName "lab.example.com" -RecordName "ldaps" -IPv4Addresses @("192.168.61.161", "192.168.61.162") -TtlSeconds 30
```

### `maxdc02`

```powershell
$domainCred = Get-Credential "LAB\Administrator"
$dsrmPassword = Read-Host "Enter DSRM password" -AsSecureString
.\scripts\windows\02-install-additional-dc.ps1 -DomainName "lab.example.com" -DomainCredential $domainCred -SafeModeAdministratorPassword $dsrmPassword
.\scripts\windows\03-configure-dns.ps1 -Forwarders @("1.1.1.1", "8.8.8.8")
.\scripts\windows\05-request-ldaps-certificate.ps1 -CAConfig "maxdc03.lab.example.com\MAXLAB-ROOT-CA" -DomainFqdn "lab.example.com" -RoundRobinName "ldaps.lab.example.com" -RebootAfterEnrollment
```

### `maxdc03`

```powershell
$domainCred = Get-Credential "LAB\Administrator"
$dsrmPassword = Read-Host "Enter DSRM password" -AsSecureString
.\scripts\windows\02-install-additional-dc.ps1 -DomainName "lab.example.com" -DomainCredential $domainCred -SafeModeAdministratorPassword $dsrmPassword
.\scripts\windows\03-configure-dns.ps1 -Forwarders @("1.1.1.1", "8.8.8.8")
.\scripts\windows\04-install-enterprise-root-ca-maxdc03.ps1 -CACommonName "MAXLAB-ROOT-CA" -ValidityYears 10 -OutputPath "C:\Lab"
```
