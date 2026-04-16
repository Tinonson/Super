# LDAPS Lab – Windows Server 2022 with DNS Round-Robin HA

A complete lab for enabling **LDAPS (LDAP over SSL/TLS)** on Windows Server 2022 domain controllers with **DNS round-robin** for high availability.

## Lab Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                        max.local  (AD Forest)                       │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐    │
│  │   maxdc01     │   │   maxdc02     │   │      maxdc03         │    │
│  │ 192.168.61.161│   │ 192.168.61.162│   │  192.168.61.163      │    │
│  │               │   │               │   │                      │    │
│  │  Domain Ctrl  │   │  Domain Ctrl  │   │  Domain Controller   │    │
│  │  DNS Server   │   │  DNS Server   │   │  DNS Server          │    │
│  │  LDAPS ✓      │   │  LDAPS ✓      │   │  Enterprise Root CA  │    │
│  └───────┬───────┘   └───────┬───────┘   └──────────────────────┘    │
│          │                   │                                       │
│          └─────────┬─────────┘                                       │
│                    │                                                  │
│        ┌───────────┴───────────┐                                     │
│        │  ldaps.max.local      │                                     │
│        │  (DNS round-robin)    │                                     │
│        │  -> 192.168.61.161    │                                     │
│        │  -> 192.168.61.162    │                                     │
│        └───────────┬───────────┘                                     │
└────────────────────┼────────────────────────────────────────────────┘
                     │
              ┌──────┴──────┐
              │ Ubuntu Client│
              │  ldapsearch  │
              └─────────────┘
```

| Server   | IP               | Roles                                |
|----------|------------------|--------------------------------------|
| maxdc01  | 192.168.61.161   | DC, DNS, LDAPS                       |
| maxdc02  | 192.168.61.162   | DC, DNS, LDAPS                       |
| maxdc03  | 192.168.61.163   | DC, DNS, Enterprise Root CA          |

- **Domain**: `max.local`
- **LDAPS endpoint**: `ldaps://ldaps.max.local:636`
- **HA method**: DNS round-robin between maxdc01 and maxdc02

## Scripts

| # | Script | Run On | Purpose |
|---|--------|--------|---------|
| 1 | `01-Install-ADDS-Role.ps1` | All 3 servers | Install AD DS and promote DCs |
| 2 | `02-Configure-DNS.ps1` | All 3 servers | Configure DNS zones and records |
| 3 | `03-Enable-LDAPs.ps1` | maxdc01, maxdc02 | Bind certificate and enable LDAPS |
| 4 | `04-Install-CA-And-Generate-Certs.ps1` | maxdc03 only | Install Enterprise CA, create templates, issue certs |
| 5 | `05-Configure-DNS-RoundRobin.ps1` | Any DC | Create round-robin A records for HA |
| 6 | `06-Test-LDAPs-Ubuntu-Client.sh` | Ubuntu client | End-to-end LDAPS and HA tests |

## Execution Order

Follow these steps in order. Each step includes the exact commands to run.

### Step 1: Install AD DS and Create the Forest

**On maxdc01** (first — creates the forest):

```powershell
.\scripts\01-Install-ADDS-Role.ps1 -Role FirstDC
# Server will reboot automatically
```

**On maxdc02 and maxdc03** (after maxdc01 reboots — join existing domain):

```powershell
.\scripts\01-Install-ADDS-Role.ps1 -Role AdditionalDC
# Will prompt for MAX\Administrator credentials
# Server will reboot automatically
```

> Wait for all three servers to reboot and come back online before continuing.

### Step 2: Configure DNS

**On each server** (maxdc01, maxdc02, maxdc03):

```powershell
.\scripts\02-Configure-DNS.ps1
```

This creates forward/reverse zones, registers A/PTR records for all DCs, and sets each server to use all three DCs for DNS resolution.

### Step 3: Install Certificate Authority

**On maxdc03 only:**

```powershell
.\scripts\04-Install-CA-And-Generate-Certs.ps1
```

This installs the Enterprise Root CA (`MAX-ROOT-CA`), creates a certificate template for LDAPS, and publishes it.

### Step 4: Enroll Certificates on DCs

**On maxdc01 and maxdc02**, trigger certificate auto-enrollment:

```powershell
gpupdate /force
certutil -pulse
```

Verify a certificate was issued:

```powershell
Get-ChildItem Cert:\LocalMachine\My | Format-List Subject, Thumbprint, NotAfter
```

You should see a certificate with Server Authentication EKU.

### Step 5: Enable LDAPS

**On maxdc01 and maxdc02:**

```powershell
.\scripts\03-Enable-LDAPs.ps1
```

This binds the certificate to NTDS and restarts the service. LDAPS will be active on port 636.

### Step 6: Configure DNS Round-Robin

**On any DC** (e.g., maxdc01):

```powershell
.\scripts\05-Configure-DNS-RoundRobin.ps1
```

This creates two A records for `ldaps.max.local` pointing to both maxdc01 and maxdc02, enables round-robin, and verifies the configuration.

### Step 7: Test from Ubuntu Client

**On the Ubuntu client:**

```bash
# Configure DNS to point to the AD servers
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 192.168.61.161
nameserver 192.168.61.162
nameserver 192.168.61.163
search max.local
EOF'

# Run the test suite
chmod +x scripts/06-Test-LDAPs-Ubuntu-Client.sh
sudo ./scripts/06-Test-LDAPs-Ubuntu-Client.sh
```

The test script runs 7 tests:
1. DNS resolution for all DCs and the round-robin hostname
2. TCP connectivity to port 636
3. TLS certificate inspection
4. Anonymous LDAPS query
5. Authenticated LDAPS bind
6. Round-robin rotation (10 queries)
7. Failover simulation guide

## Quick Verification Commands

### From any Windows DC:

```powershell
# Check LDAPS port
Test-NetConnection -ComputerName ldaps.max.local -Port 636

# Check certificate
Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1"
}

# Verify DNS round-robin
Resolve-DnsName ldaps.max.local -Type A
```

### From the Ubuntu client:

```bash
# Quick LDAPS test
LDAPTLS_REQCERT=never ldapsearch -H ldaps://ldaps.max.local:636 -x -b "" -s base

# Check certificate
echo | openssl s_client -connect ldaps.max.local:636 2>/dev/null | openssl x509 -noout -text

# Verify DNS round-robin
dig ldaps.max.local A +short
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| LDAPS not responding on 636 | Verify certificate has Server Auth EKU: `certutil -verifystore My` |
| DNS not resolving | Check DNS client config: `Get-DnsClientServerAddress` |
| Round-robin shows one IP | Flush DNS cache; disable `LocalNetPriority` in DNS server settings |
| Certificate enrollment fails | Verify CA is running: `certutil -ping`; check template permissions |
| Ubuntu TLS errors | Set `LDAPTLS_REQCERT=never` for lab, or import the CA cert to `/usr/local/share/ca-certificates/` |

## Importing the CA Certificate on Ubuntu (Optional)

For production-like TLS validation without `LDAPTLS_REQCERT=never`:

```bash
# Export the CA cert from any DC
# On Windows: certutil -ca.cert ca.cer

# Copy to Ubuntu and install
sudo cp ca.cer /usr/local/share/ca-certificates/max-root-ca.crt
sudo update-ca-certificates

# Now ldapsearch will validate the certificate chain
ldapsearch -H ldaps://ldaps.max.local:636 -x -b "" -s base
```

## Credentials

| Item | Value |
|------|-------|
| Domain | `max.local` |
| NetBIOS | `MAX` |
| DSRM Password | `P@ssw0rd!2025` |
| CA Name | `MAX-ROOT-CA` |
| LDAPS Hostname | `ldaps.max.local` |
