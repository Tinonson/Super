#!/usr/bin/env bash
set -euo pipefail

LDAPS_HOST="${LDAPS_HOST:-ldaps.lab.example.com}"
DNS_SERVER="${DNS_SERVER:-192.168.61.161}"
CA_CERT="${CA_CERT:-/usr/local/share/ca-certificates/MAXLAB-ROOT-CA.crt}"
BIND_DN="${BIND_DN:-CN=Administrator,CN=Users,DC=lab,DC=example,DC=com}"
BIND_PASSWORD="${BIND_PASSWORD:-ChangeMe!}"
BASE_DN="${BASE_DN:-DC=lab,DC=example,DC=com}"
ROUNDS="${ROUNDS:-6}"

echo "[1/3] DNS round-robin answers for ${LDAPS_HOST}"
for i in $(seq 1 "${ROUNDS}"); do
  echo "Attempt ${i}"
  dig +short @"${DNS_SERVER}" "${LDAPS_HOST}" A
  sleep 1
done

echo
echo "[2/3] TLS handshake and certificate validation"
openssl s_client \
  -connect "${LDAPS_HOST}:636" \
  -servername "${LDAPS_HOST}" \
  -CAfile "${CA_CERT}" < /dev/null 2>/dev/null | \
  awk '/subject=|issuer=|Verify return code/'

echo
echo "[3/3] LDAP bind and RootDSE query over LDAPS"
LDAPTLS_CACERT="${CA_CERT}" \
ldapsearch \
  -H "ldaps://${LDAPS_HOST}:636" \
  -x \
  -D "${BIND_DN}" \
  -w "${BIND_PASSWORD}" \
  -b "" \
  -s base \
  defaultNamingContext dnsHostName supportedLDAPVersion

echo
echo "[3b/3] Example search under ${BASE_DN}"
LDAPTLS_CACERT="${CA_CERT}" \
ldapsearch \
  -H "ldaps://${LDAPS_HOST}:636" \
  -x \
  -D "${BIND_DN}" \
  -w "${BIND_PASSWORD}" \
  -b "${BASE_DN}" \
  -s sub \
  "(objectClass=computer)" \
  dNSHostName | awk '/^dn:|^dNSHostName:/'

echo
echo "Failover note:"
echo "- Temporarily block TCP/636 on maxdc01 or power it off."
echo "- Wait for the 30-second DNS TTL to expire, or flush any local resolver cache."
echo "- Run this script again to confirm the client can still bind through maxdc02."
echo "- DNS round-robin is not health-aware, so brief failures are expected if the first returned IP is offline."
