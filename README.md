# Windows Server 2022 LDAPS Load Balancer (Lab Guide)

This guide shows how to build a **test lab** for LDAPS (TCP/636) behind a load-balanced virtual IP (VIP) using **Windows Server 2022 Network Load Balancing (NLB)**.

> Important:
> - This is a **lab-focused** setup.
> - For production, use a dedicated ADC/load balancer (F5, NetScaler, HAProxy, Kemp, etc.) with health checks and better observability.
> - Keep LDAPS in **TCP pass-through** mode. Do not terminate/re-encrypt TLS unless your security policy explicitly allows it.

---

## 1) Lab topology

| Host | Role | Example IP |
|---|---|---|
| DC1 | AD DS + DNS + LDAPS + NLB node | 10.10.10.11 |
| DC2 | AD DS + DNS + LDAPS + NLB node | 10.10.10.12 |
| CLIENT1 | Domain-joined test client | 10.10.10.50 |
| VIP | NLB cluster IP for LDAPS | 10.10.10.20 |

Domain/FQDN examples:
- AD domain: `lab.local`
- LDAPS LB name: `ldaps-lb.lab.local`

---

## 2) Prerequisites

1. Two Windows Server 2022 machines promoted as Domain Controllers.
2. Time sync working (Kerberos-safe time skew).
3. Enterprise CA (recommended) or valid server certificates for each DC:
   - EKU includes **Server Authentication** (`1.3.6.1.5.5.7.3.1`)
   - Subject/SAN includes each DC FQDN (`dc1.lab.local`, `dc2.lab.local`)
4. Firewall allows TCP/636 between client and DCs.
5. DNS resolution working for domain and future VIP.

---

## 3) Configure LDAPS on each DC

### 3.1 Request/install certificate

Use the **Domain Controller Authentication** (or equivalent) template.

Quick check on each DC:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
  Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.1" } |
  Select-Object Subject, NotAfter, Thumbprint
```

### 3.2 Restart AD DS service (or reboot)

```powershell
Restart-Service NTDS -Force
```

### 3.3 Validate LDAPS listener on each DC

```powershell
Test-NetConnection dc1.lab.local -Port 636
Test-NetConnection dc2.lab.local -Port 636
```

Optional (from CLIENT1):

```powershell
openssl s_client -connect dc1.lab.local:636 -showcerts
openssl s_client -connect dc2.lab.local:636 -showcerts
```

---

## 4) Build Windows NLB cluster for LDAPS VIP (lab)

Install NLB feature on both DCs:

```powershell
Install-WindowsFeature NLB -IncludeManagementTools
```

### 4.1 Create NLB cluster (run on DC1)

```powershell
Import-Module NetworkLoadBalancingClusters

New-NlbCluster `
  -InterfaceName "Ethernet" `
  -ClusterPrimaryIP 10.10.10.20 `
  -SubnetMask 255.255.255.0 `
  -OperationMode Unicast `
  -ClusterName "ldaps-lb.lab.local"
```

### 4.2 Add second host (run on DC1)

```powershell
Add-NlbClusterNode `
  -HostName "dc2.lab.local" `
  -NewNodeInterface "Ethernet"
```

### 4.3 Restrict port rules to LDAPS only

Remove default all-ports rule and add TCP 636 rule:

```powershell
Get-NlbClusterPortRule | Remove-NlbClusterPortRule -Force

Add-NlbClusterPortRule `
  -StartPort 636 -EndPort 636 `
  -Protocol TCP `
  -Mode Multiple `
  -Affinity None
```

### 4.4 DNS entry for VIP

Create A record:
- `ldaps-lb.lab.local` -> `10.10.10.20`

---

## 5) Test lab steps (end-to-end)

Run these from CLIENT1 (domain joined).

### Step 1: Basic reachability

```powershell
Test-NetConnection ldaps-lb.lab.local -Port 636
```

Expected: `TcpTestSucceeded : True`

### Step 2: TLS handshake and certificate chain

```powershell
openssl s_client -connect ldaps-lb.lab.local:636 -showcerts
```

Expected:
- Handshake succeeds
- Certificate presented by one DC
- Cert chains to trusted CA

### Step 3: LDAP bind test using ldp.exe

1. Open `ldp.exe`.
2. **Connection > Connect**
   - Server: `ldaps-lb.lab.local`
   - Port: `636`
   - Check **SSL**
3. **Connection > Bind** with test user credentials.
4. Perform a simple search under your base DN.

Expected: successful bind and query.

### Step 4: Load distribution observation

From CLIENT1, run multiple connection attempts:

```powershell
1..20 | ForEach-Object {
  Test-NetConnection ldaps-lb.lab.local -Port 636 | Out-Null
}
```

Check active connections/counters on both DCs (or logs) to see traffic hit both nodes.

### Step 5: Failover test

1. On DC1, stop node handling:
   ```powershell
   Stop-NlbClusterNode -HostName dc1.lab.local -Drain
   ```
2. Repeat Step 1 and Step 3 from CLIENT1.

Expected: LDAPS stays available through DC2.

### Step 6: Node recovery test

```powershell
Start-NlbClusterNode -HostName dc1.lab.local
```

Repeat bind tests and confirm both nodes can again serve traffic.

---

## 6) Health check and monitoring suggestions

- Use TCP 636 probes at minimum.
- Add synthetic LDAP bind checks from a monitor host.
- Track:
  - Schannel errors (TLS)
  - Directory Service logs
  - NLB convergence events

---

## 7) Common issues and fixes

1. **Handshake fails / unknown CA**
   - Root/intermediate CA not trusted on client.
2. **LDAPS does not start on DC**
   - Wrong cert EKU/SAN or cert not in LocalMachine\My.
3. **Intermittent connection drops**
   - NLB convergence/network mode mismatch, NIC teaming conflicts.
4. **Bind works on DC directly but not VIP**
   - NLB port rule missing for TCP/636 or firewall path blocked.

---

## 8) Production notes

- Prefer dedicated load balancers with:
  - Better health probes (bind/search checks)
  - Session visibility and logging
  - HA pair support and cleaner failover behavior
- Keep certificates and cipher policies aligned across all DCs.
- Document break-glass method to bypass VIP and target a specific DC directly.
