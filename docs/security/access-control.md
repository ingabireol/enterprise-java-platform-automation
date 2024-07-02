# Access control model

Who can reach what, how they authenticate, and how access is removed.

---

## Principles

1. **Individual accounts only.** No shared credentials anywhere. After an
   incident it must be possible to say who did what, and an offboarding must be
   able to actually complete.
2. **Access by group, not by person.** Membership of a group grants access;
   nobody is named in a sudoers file or a `pg_hba.conf` line.
3. **Least privilege, meant literally.** `platform-ops` can restart services and
   read logs. It cannot install packages or read `/etc/shadow`, because the daily
   work does not require it.
4. **All human access through the jump host.** Application and database nodes
   accept SSH only from the management network.
5. **Service accounts are not login accounts.** `efpsvc` and `tomcat` have
   `/sbin/nologin` and no authorised keys.

---

## Human access

### Groups

| Group | GID | Members | Host access | Sudo |
| --- | --- | --- | --- | --- |
| `sysadmins` | 4000 | Platform engineers | All hosts | `ALL=(ALL) ALL`, password required |
| `platform-ops` | 4001 | Operations, on-call | All hosts | `systemctl`, `journalctl`, `/opt/efp/bin/*` — NOPASSWD |
| `dba` | 4002 | Database administrators | Database hosts | `(postgres) ALL` — NOPASSWD |
| `developers` | 4003 | Application developers | `dev` only | None |
| `auditors` | 4004 | Internal audit | Read-only, all hosts | None |

### Authentication

- SSH keys only. ed25519 required for new keys; existing RSA keys must be ≥ 2048
  bits and are flagged for replacement by `scripts/security/account_audit.sh`.
- Jump host requires key **and** a second factor.
- Passwords exist only for `sudo` re-authentication on `sysadmins`, subject to
  the ageing and complexity policy in the hardening baseline.

### The path in

```
Engineer ──key+MFA──▶ Jump host ──key──▶ Platform host
                          │
                          └── session recorded; this is the only ingress
```

Direct SSH from a workstation to an application or database host is blocked by
the host firewall, not merely discouraged.

---

## Service accounts

| Account | Purpose | Shell | Credentials |
| --- | --- | --- | --- |
| `efpsvc` | Runs the Spring Boot services | `/sbin/nologin` | None — systemd starts it |
| `tomcat` | Runs Tomcat | `/sbin/nologin` | None |
| `postgres` | PostgreSQL | `/bin/bash` | Peer authentication locally only |
| `node_exporter` | Metrics | `/sbin/nologin` | None |
| `postgres_exporter` | Database metrics | `/sbin/nologin` | Database role `pg_exporter`, `pg_monitor` only |

---

## Database access

| Role | Privileges | Used by | Authentication |
| --- | --- | --- | --- |
| `efp_app` | Owner of the application schema; no superuser, no createdb | The application services | `scram-sha-256` over TLS, from the application hosts only |
| `efp_ro` | `SELECT` on all current and future tables | Reporting, ad-hoc analysis | `scram-sha-256` over TLS |
| `replicator` | `REPLICATION` only | Streaming replication, `pg_basebackup` | `scram-sha-256` over TLS, from database and backup hosts only |
| `pg_exporter` | `pg_monitor` | Metrics | Local connection only |
| `postgres` | Superuser | Administration | Peer authentication on the local socket; never over the network |

`pg_hba.conf` names each source host explicitly and ends with a reject rule.
There is no `host all all 0.0.0.0/0` line anywhere in it.

The read-only role exists so that reporting and investigation never need
application credentials. Without it, "I just need to check something" becomes a
reason to hand out write access.

---

## Secrets

| Secret | Stored in | Rotation |
| --- | --- | --- |
| Database passwords | Ansible Vault (`group_vars/*/vault.yml`) | Annually, or on personnel change |
| TLS private keys | On the host, mode 0600, never in git | With the certificate |
| Vault password | Operator's password manager; never on disk in the repository | On personnel change |
| Backup encryption passphrase | Ansible Vault + offline escrow | Annually |
| SSH host keys | Generated on the host | On rebuild |

**Nothing secret is committed.** `.gitignore` covers the obvious shapes
(`*.key`, `*.pem`, `vault.yml`, `.env`) and a pre-commit hook scans for
high-entropy strings. Neither is sufficient alone; both together catch most
accidents.

```bash
ansible-vault encrypt ansible/inventories/prod/group_vars/vault.yml
ansible-vault edit    ansible/inventories/prod/group_vars/vault.yml
ansible-vault rekey   ansible/inventories/prod/group_vars/vault.yml   # after a departure
```

---

## Joining

1. Manager requests access, naming the group.
2. Account created by Ansible with the requested group membership; ed25519 public
   key supplied by the engineer.
3. Jump host access and second factor enrolled.
4. Grafana and Alertmanager access granted.
5. Vault password issued through the agreed channel — never by email or chat.
6. Recorded in the access register.

---

## Leaving

Within **one working day**, and immediately for an involuntary departure:

```bash
# 1. Lock the account and remove group membership everywhere
ansible -i ansible/inventories/prod/hosts.yml platform -m user \
  -a "name=<username> state=absent remove=yes" --become

# 2. Remove authorised keys (belt and braces — the account removal covers this)
ansible -i ansible/inventories/prod/hosts.yml platform -m file \
  -a "path=/home/<username>/.ssh/authorized_keys state=absent" --become

# 3. Revoke jump host and MFA enrolment

# 4. Rekey the vault if they held the password
ansible-vault rekey ansible/inventories/*/group_vars/vault.yml

# 5. Rotate any shared secret they had access to
#    (database passwords, backup passphrase)

# 6. Confirm
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "getent passwd <username> || echo absent"
```

Step 4 is the one most often skipped, and it is the one that matters most: a
departed engineer with the vault password retains access to every credential in
the estate regardless of what happened to their account.

---

## Reviewing

**Quarterly**, and after any departure:

```bash
# Per-host account and privilege review
ansible -i ansible/inventories/prod/hosts.yml platform -m script \
  -a "scripts/security/account_audit.sh --json" --become

# Database roles
ssh db-prod-01 "sudo -u postgres psql -c '\du'"

# Who has actually logged in recently
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "lastlog -t 90" --become
```

The review asks three questions: does everyone with access still need it, does
anyone have more than their role requires, and is there anything here nobody can
account for. The third question is the interesting one.
