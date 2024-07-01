# Runbook: TLS certificate rotation

**An expired certificate is a complete outage that arrives on a schedule you were
told about months in advance. It is the least excusable kind.**

---

## Monitoring

`scripts/security/tls_audit.sh` runs daily and exports days-to-expiry to
Prometheus. Alerts fire at 30 days (warning) and 14 days (critical).

```bash
# Check any endpoint now
./scripts/security/tls_audit.sh --host efp.example.gov --port 443

# Every certificate on every host
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "for c in /etc/pki/tls/certs/*.crt; do echo -n \"\$c: \"; openssl x509 -enddate -noout -in \$c; done"
```

---

## Rotation, planned

Start 30 days before expiry. The certificate authority is never as fast as the
runbook assumes.

### Step 1 — Generate a key and CSR

```bash
ssh lb-prod-01 'sudo openssl req -new -newkey rsa:2048 -nodes \
  -keyout /etc/pki/tls/private/efp.example.gov.key.new \
  -out /tmp/efp.example.gov.csr \
  -subj "/C=RW/ST=Kigali/L=Kigali/O=Example Organisation/CN=efp.example.gov" \
  -addext "subjectAltName=DNS:efp.example.gov,DNS:www.efp.example.gov"'

ssh lb-prod-01 'sudo chmod 600 /etc/pki/tls/private/efp.example.gov.key.new'
```

Generate a **new key**, not a reused one. Key reuse means a compromise of the old
key compromises the new certificate too, which defeats the point of rotation.

### Step 2 — Verify the CSR before submitting it

```bash
ssh lb-prod-01 'openssl req -text -noout -verify -in /tmp/efp.example.gov.csr | head -20'
```

Check the CN and every SAN. A certificate missing a SAN that clients use produces
an outage for exactly those clients and nobody else, which is the hardest kind to
diagnose.

### Step 3 — Submit and wait

Submit to the certificate authority. Note the expected turnaround in the change
record so the timeline is visible.

### Step 4 — Verify the issued certificate

Before deploying anything:

```bash
# Does the certificate match the private key? (The two hashes must be identical.)
openssl x509 -noout -modulus -in efp.example.gov.crt.new | openssl md5
openssl rsa  -noout -modulus -in efp.example.gov.key.new | openssl md5

# Does the chain verify?
openssl verify -CAfile chain.crt efp.example.gov.crt.new

# Are the SANs what you asked for?
openssl x509 -text -noout -in efp.example.gov.crt.new | grep -A1 "Subject Alternative Name"

# When does it expire?
openssl x509 -enddate -noout -in efp.example.gov.crt.new
```

A mismatch between certificate and key is the most common rotation failure and it
takes nginx down on reload. Checking costs ten seconds.

### Step 5 — Deploy, one edge node at a time

```bash
for node in lb-prod-01 lb-prod-02; do
  # Back out the old material first
  ssh $node "sudo cp /etc/pki/tls/certs/efp.example.gov.crt /etc/pki/tls/certs/efp.example.gov.crt.$(date +%F)"
  ssh $node "sudo cp /etc/pki/tls/private/efp.example.gov.key /etc/pki/tls/private/efp.example.gov.key.$(date +%F)"

  scp efp.example.gov.crt.new $node:/tmp/
  scp chain.crt $node:/tmp/
  ssh $node "sudo mv /tmp/efp.example.gov.crt.new /etc/pki/tls/certs/efp.example.gov.crt"
  ssh $node "sudo mv /tmp/chain.crt /etc/pki/tls/certs/efp.example.gov-chain.crt"
  ssh $node "sudo mv /etc/pki/tls/private/efp.example.gov.key.new /etc/pki/tls/private/efp.example.gov.key"
  ssh $node "sudo chmod 644 /etc/pki/tls/certs/efp.example.gov.crt"
  ssh $node "sudo chmod 600 /etc/pki/tls/private/efp.example.gov.key"

  # Validate BEFORE reloading — nginx -t catches a mismatch without dropping traffic
  ssh $node "sudo nginx -t" || { echo "Configuration invalid on $node — stopping"; break; }
  ssh $node "sudo systemctl reload nginx"

  # Confirm from outside
  echo | openssl s_client -connect $node:443 -servername efp.example.gov 2>/dev/null \
    | openssl x509 -noout -enddate -subject
done
```

A reload, not a restart: existing connections finish on the old worker processes
while new ones use the new certificate. Users see nothing.

### Step 6 — Verify and record

```bash
./scripts/security/tls_audit.sh --host efp.example.gov
```

Update the expiry date wherever your team tracks renewals. Then delete the old
key material after a week — long enough to roll back, short enough that a
superseded private key is not lying around indefinitely.

---

## An expired certificate (outage in progress)

Users are seeing certificate warnings and the platform is effectively down.

**Fastest path back to service:**

1. **Is a valid replacement already issued and sitting somewhere?** Very often it
   is — it was issued and never deployed. Deploy it (Step 5 above). Two minutes.
2. **Is the certificate authority reachable?** An emergency re-issue is typically
   under an hour for a domain-validated certificate.
3. **Neither?** For an internal-only platform, an internally signed certificate
   restores service while the real one is obtained. For a public service this is
   not an option — browsers will reject it.

**Do not disable TLS.** Downgrading to plaintext to "restore service" turns a
visible outage into an invisible data exposure, and someone will forget to
re-enable it.

---

## Other certificates in the estate

| Certificate | Location | Lifetime | Rotation |
| --- | --- | --- | --- |
| Edge server certificate | `/etc/pki/tls/certs/` on edge nodes | 1 year | This runbook |
| PostgreSQL server certificate | `$PGDATA/server.crt` | 825 days | Regenerate via the `postgresql` role, reload |
| Internal service certificates | Per host | 1 year | Regenerate via Ansible |
| Java trust store additions | `/etc/pki/ca-trust/source/anchors/` | Per partner | `java_extra_ca_certs` in group_vars |

The PostgreSQL certificate expiring is a quieter failure than the edge one: with
`sslmode=require` the application simply stops connecting, which looks like a
database outage. Worth knowing before you spend an hour on the database.
