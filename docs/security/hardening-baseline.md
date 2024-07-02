# Security hardening baseline

The controls applied to every host, why each one is there, and how compliance is
measured. Aligned with the CIS Benchmark for RHEL 9 and adapted where the
benchmark conflicts with running an enterprise Java platform — every such
deviation is recorded below rather than silently applied.

**Measured by:** `ansible-playbook playbooks/compliance-audit.yml` (read-only).
**Applied by:** `ansible/roles/hardening`.

---

## Profiles

| Profile | Applied to | Posture |
| --- | --- | --- |
| `baseline` | `dev` | Same controls, thresholds that do not obstruct a developer debugging on a shared box |
| `strict` | `test`, `prod`, `dr` | Assumes all access is via a jump host with key and MFA, and no human logs in to an application node directly |

`test` runs `strict` deliberately. A test environment hardened differently from
production tests the wrong thing.

---

## 1. Access and authentication

| Control | Setting | Why |
| --- | --- | --- |
| SSH root login | `no` | Attribution. Root actions must be traceable to a person through `sudo`. |
| Password authentication | `no` | Removes brute force and credential stuffing as attack paths entirely. |
| Authentication methods | `publickey` | A single, auditable mechanism. |
| Key algorithms | ed25519 preferred, RSA ≥ 2048 accepted | DSA and short RSA are no longer defensible. |
| Ciphers | ChaCha20-Poly1305, AES-GCM, AES-CTR | AEAD ciphers only; CBC removed. |
| MACs | `*-etm@openssh.com` (SHA-2) | Encrypt-then-MAC; SHA-1 MACs removed. |
| `MaxAuthTries` | 3 (strict) / 5 (baseline) | Bounds an attempt before `fail2ban` reacts. |
| `AllowGroups` | `sysadmins`, `platform-ops` | Explicit allow list; a new account gets no access by default. |
| `ClientAliveInterval` | 300s, 2 misses | Reaps abandoned sessions. |
| `PermitEmptyPasswords` | `no` | — |
| Login banner | `/etc/issue.net` | Legal notice presented before authentication. |

**Deviation from CIS:** `AllowTcpForwarding` is `yes` in the `baseline` profile.
Developers tunnel to the database and actuator ports; forbidding it would move the
traffic to something less controlled. It is `no` in `strict`.

---

## 2. Accounts and privilege

| Control | Setting |
| --- | --- |
| Password maximum age | 90 days |
| Password minimum length | 14 characters, 3 character classes |
| Password history | 5 |
| Hashing | SHA-512, ≥ 10,000 rounds |
| Inactive account lock | 35 days |
| Default umask | 027 |
| `cron`/`at` access | Allow list containing only `root` |

Sudo is granted by group, scoped to the role:

| Group | Grant | Rationale |
| --- | --- | --- |
| `sysadmins` | `ALL=(ALL) ALL` | Full administration, password required |
| `platform-ops` | `systemctl`, `journalctl`, `/opt/efp/bin/*` — NOPASSWD | The daily operational commands, without full root |
| `dba` | `(postgres) ALL` — NOPASSWD | Database administration without host root |
| `auditors` | none | Read-only access; no privilege escalation at all |

The `platform-ops` grant is deliberately narrow. Most operational work is
restarting a service, reading a log, or running a platform script — none of which
needs root over the whole host.

---

## 3. Kernel and network stack

| Setting | Value | Why |
| --- | --- | --- |
| `net.ipv4.ip_forward` | 0 | These hosts are not routers. |
| `accept_redirects`, `send_redirects` | 0 | ICMP redirects allow route manipulation. |
| `accept_source_route` | 0 | Source routing bypasses routing policy. |
| `rp_filter` | 1 | Reverse path filtering rejects spoofed sources. |
| `tcp_syncookies` | 1 | Survives a SYN flood without dropping legitimate connections. |
| `log_martians` | 1 | Records impossible source addresses — an early signal. |
| `kernel.randomize_va_space` | 2 | Full ASLR. |
| `kernel.dmesg_restrict` | 1 | The kernel log leaks addresses useful for exploitation. |
| `kernel.kptr_restrict` | 2 | Hides kernel pointers from unprivileged processes. |
| `kernel.yama.ptrace_scope` | 1 | Prevents one process attaching to another's memory. |
| `fs.suid_dumpable` | 0 | A core dump from a setuid binary can contain secrets. |
| `fs.protected_hardlinks`, `protected_symlinks` | 1 | Closes a classic symlink race. |

Filesystem and protocol modules with no role here are blacklisted: `cramfs`,
`freevxfs`, `jffs2`, `hfs`, `hfsplus`, `squashfs`, `udf`, `usb-storage`, `dccp`,
`sctp`, `rds`, `tipc`. Removing attack surface is cheaper than monitoring it.

---

## 4. Host firewall

Default-deny inbound `nftables` on every host, rendered per host from the
Ansible inventory so that a host only opens the ports for the roles it carries.

| Host role | Inbound permitted |
| --- | --- |
| All | SSH from the management network (rate-limited); `node_exporter` from the monitoring host |
| Edge | 80, 443 from anywhere; VRRP between the edge peers |
| Application | Service ports from the edge nodes only; actuator ports from the monitoring host only |
| Database | 5432 from application, database and backup hosts only; 9187 from monitoring |
| Monitoring | UIs from the management network; Loki ingest from the platform hosts |

The north–south perimeter lives on the network devices (see the companion
[`enterprise-network-operations`](../../../enterprise-network-operations)
repository). This layer assumes the perimeter has already failed.

---

## 5. Mandatory access control

SELinux `enforcing` with the `targeted` policy on `test`, `prod` and `dr`;
`permissive` on `dev` so that a new denial surfaces as a log entry rather than as
a blocked developer.

**SELinux is never disabled to make something work.** When a denial blocks a
legitimate action, the fix is a policy module:

```bash
ausearch -m AVC -ts recent | audit2allow -M efp-local
semodule -i efp-local.pp
```

---

## 6. Audit logging

`auditd` with a rule set scoped to one question: **who changed what, when, from
where.** Not a general-purpose event firehose — an audit log nobody can search is
an audit log nobody reads.

| Rule key | Covers |
| --- | --- |
| `identity` | `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` |
| `privilege` | `/etc/sudoers`, `/etc/sudoers.d/` |
| `privilege_escalation` | `execve` where effective UID becomes 0 |
| `platform_config` | `/opt/efp/etc/`, `/opt/efp/bin/` |
| `systemd_units` | `/etc/systemd/system/` |
| `time_change` | `adjtimex`, `settimeofday`, `clock_settime` |
| `network_config` | `/etc/hosts`, firewall configuration, hostname changes |
| `modules` | Kernel module load and unload |
| `access_denied` | `EACCES`/`EPERM` on file access by a real user |

On `prod` and `dr` the rule set is made immutable until reboot (`-e 2`), so an
attacker with root cannot quietly disable auditing without leaving a reboot in
the record.

`disk_full_action = halt`: a host that cannot record what is happening to it
should stop, not continue unobserved. This is a deliberate availability trade —
reviewed and accepted by the service owner.

---

## 7. File integrity

AIDE, initialised on first converge and checked daily. A difference is a signal
to investigate, not an automatic alarm — package updates legitimately change
files, and the check exists to make the illegitimate changes visible against that
background.

---

## 8. Brute-force protection

`fail2ban` watching `sshd` and, on the edge nodes, nginx authentication and rate
limit events. The management network and the monitoring host are never banned:
locking out your own monitoring during an incident is a self-inflicted wound.

| Profile | Ban | Window | Attempts |
| --- | --- | --- | --- |
| `strict` | 3600s | 600s | 3 |
| `baseline` | 600s | 600s | 10 |

---

## 9. Service reduction

Masked on every host: `avahi-daemon`, `cups`, `rpcbind`, `nfs-server`,
`bluetooth`, `telnet.socket`. Masked rather than merely disabled, so a dependency
cannot pull them back.

---

## 10. File permissions

| Path | Mode |
| --- | --- |
| `/etc/shadow`, `/etc/gshadow` | 0000 |
| `/etc/passwd`, `/etc/group` | 0644 |
| `/etc/ssh/sshd_config` | 0600 |
| `/etc/crontab` | 0600 |
| `/boot/grub2/grub.cfg` | 0600 |
| `/opt/efp/etc/*` | 0640, group `efpsvc` |

---

## 11. Application-level hardening

Beyond the OS:

- **systemd sandboxing** on every service unit: `NoNewPrivileges`, `PrivateTmp`,
  `ProtectSystem=strict`, `ProtectHome`, `ProtectKernelTunables`,
  `ProtectKernelModules`, `RestrictSUIDSGID`, `SystemCallFilter=@system-service`,
  and an explicit `ReadWritePaths` list. A compromised service can write to its
  own log and data directories and nothing else.
- **Tomcat**: shutdown port disabled (`-1`), sample and manager applications
  removed, `server`/`xpoweredBy` banners suppressed, `LockOutRealm` enabled.
- **nginx**: `server_tokens off`, HSTS, CSP, `X-Content-Type-Options`,
  `Referrer-Policy`, `Permissions-Policy`, per-IP rate and connection limits,
  tighter limits on the authentication path.
- **PostgreSQL**: TLS required for every network connection, `scram-sha-256`,
  explicit `pg_hba.conf` with a final reject rule and no wildcard host line,
  `PUBLIC` revoked from the `public` schema.
- **JVM**: crypto policy set explicitly rather than inherited, managed trust
  store, actuator endpoints bound to localhost and reachable only from the
  monitoring host.

---

## 12. Deviations from CIS, recorded

| CIS item | Deviation | Reason |
| --- | --- | --- |
| Disable TCP forwarding | Permitted in `baseline` | Developers tunnel to internal ports; forbidding it drives the traffic somewhere less controlled |
| Separate `/var/log/audit` partition | Not implemented | Storage is provisioned as a single volume per host; mitigated by `space_left_action` and `disk_full_action` |
| Disable IPv6 entirely | Not implemented | IPv6 is disabled at the interface by the network configuration; module removal complicates the base image |
| `aide --check` hourly | Daily | Hourly full-filesystem checks cost more I/O than the detection latency is worth here |
| Mandatory `noexec` on `/tmp` | Implemented as `PrivateTmp` per service | Achieves the same containment without breaking package installation |

Each deviation is a judgement with a reason attached. A baseline that claims full
compliance while quietly deviating is worse than one that states its exceptions.

---

## Measuring compliance

```bash
make audit ENV=prod
```

Read-only. Produces a per-host pass/fail table and a JSON report at
`/tmp/compliance-prod/`, which CI diffs between runs so drift shows up as a
change rather than being discovered during an incident.
