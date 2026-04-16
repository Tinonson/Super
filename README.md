# Windows Server 2022 LDAPS round-robin lab

This repository contains a ready-to-run lab package for the following layout:

| Hostname | IP address | Role |
| --- | --- | --- |
| maxdc01 | 192.168.61.161 | First domain controller, DNS, LDAPS target |
| maxdc02 | 192.168.61.162 | Additional domain controller, DNS, LDAPS target |
| maxdc03 | 192.168.61.163 | Additional domain controller, DNS, Enterprise Root CA |

Artifacts included in this repo:

- `docs/ldaps-round-robin-lab.md` - end-to-end build order, variables, and testing notes
- `scripts/windows/01-install-forest-maxdc01.ps1` - create the forest on `maxdc01`
- `scripts/windows/02-install-additional-dc.ps1` - promote `maxdc02` and `maxdc03`
- `scripts/windows/03-configure-dns.ps1` - configure DNS service settings on each DC
- `scripts/windows/04-install-enterprise-root-ca-maxdc03.ps1` - install the CA on `maxdc03`
- `scripts/windows/05-request-ldaps-certificate.ps1` - request/install LDAPS certificates
- `scripts/windows/06-configure-dns-round-robin.ps1` - create the shared LDAPS DNS name
- `scripts/windows/07-test-ldaps-windows.ps1` - Windows-side DNS and LDAPS tests
- `scripts/linux/01-test-ldaps-ubuntu.sh` - Ubuntu-side LDAPS connectivity and failover checks

Important design note:

- DNS round-robin is not a health-aware load balancer. It can spread connections and help clients retry another DC after DNS refresh, but it can still return a failed IP until TTL expires or the client retries.
- Because the LDAPS client connects to a shared name, the certificate on both `maxdc01` and `maxdc02` must include the shared alias in Subject Alternative Name. The provided certificate request script handles that.

Start with `docs/ldaps-round-robin-lab.md`.
