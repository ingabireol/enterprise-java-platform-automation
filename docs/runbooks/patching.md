# Runbook: Patching

**Cycle: monthly, second Saturday, 22:00–02:00 CAT.**
**Out-of-cycle: critical severity, within 72 hours of the advisory.**

---

## Why there is a cycle

A patch cycle exists so that patching needs no decision. Without one, every patch
becomes a proposal that has to be justified, and the answer is usually "next
month" until an audit or an incident forces it. The cycle removes the question.

---

## Before the window

```bash
# What is outstanding, and how big is the job?
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "/opt/efp/bin/patch_report.sh --json" | tee /tmp/patch-preview.json

# Which hosts will reboot?
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "needs-restarting -r" --become
```

- [ ] Preview run and reviewed; anything unexpected investigated
- [ ] Backups verified within the last 7 days
- [ ] Change record approved
- [ ] Any package in a freeze added to `patch_exclude_packages`

---

## Running the cycle

```bash
# Report only, changes nothing
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/patching.yml --check

# Security updates only (the default)
make patch ENV=prod

# Everything, not just security
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/patching.yml \
  -e security_only=false
```

### The order, and why

1. **Monitoring and backup hosts** — least user-visible. If patching breaks
   something, find out here.
2. **Database replica, then primary** — the primary is gated on replication lag
   being within tolerance; patching a primary while the replica is behind widens
   the recovery window at exactly the wrong time.
3. **Application nodes, one at a time** — each drained, patched, rebooted if
   required, and health-checked before the next begins.
4. **Edge nodes, one at a time** — keepalived is stopped first so the peer takes
   the VIP deliberately rather than during a reboot.

Any health gate failure stops the run with the remaining hosts unpatched and the
platform serving.

---

## Reboots

The playbook reboots a host when `needs-restarting -r` says the running kernel or
a core library has been replaced. It does not reboot otherwise.

This matters in both directions. A host patched but not rebooted is still
running the vulnerable code — the fix is installed and inert, which is the worst
of both worlds because the report says "patched". Equally, rebooting when it was
not required burns outage budget for nothing.

```bash
# Hosts running an older kernel than the newest installed
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "echo running=\$(uname -r) newest=\$(rpm -q --last kernel | head -1 | awk '{print \$1}')"
```

---

## Out-of-cycle patching

For a critical vulnerability that cannot wait for the cycle.

```bash
# 1. Establish exposure — is the vulnerable package actually installed and reachable?
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "rpm -q <package>"

# 2. Patch that package only, one node at a time
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/patching.yml \
  -e "security_only=true" --limit appservers --forks 1

# Or, for a single package:
ansible -i ansible/inventories/prod/hosts.yml appservers -m dnf \
  -a "name=<package> state=latest" --become --forks 1
```

Record what was patched, when, and on whose authority. An emergency change still
needs a change record; it just gets one afterwards.

---

## After the cycle

```bash
# Nothing failed to come back
ansible -i ansible/inventories/prod/hosts.yml platform -m shell \
  -a "systemctl list-units --state=failed --no-legend"

# The platform is healthy
ansible -i ansible/inventories/prod/hosts.yml appservers -m shell -a "/opt/efp/bin/health_check.sh"

# Nothing is left drained
ansible -i ansible/inventories/prod/hosts.yml appservers -m shell -a "/opt/efp/bin/drain.sh --status"

# The compliance picture improved
make audit ENV=prod
```

Evidence for the change record is written to `/tmp/patch-evidence/` on the
control node: a package list per host, before and after.

---

## When patching breaks something

The most common failures, in order of frequency:

| Symptom | Usual cause | Action |
| --- | --- | --- |
| A service will not start after reboot | A configuration file replaced by the package | `rpm -qa --last` to find what updated; look for `.rpmnew`/`.rpmsave` files |
| SELinux denials after patching | New policy version with tighter rules | `ausearch -m AVC -ts recent`; generate a policy module rather than disabling SELinux |
| Host will not come back from reboot | Kernel or initramfs problem | Boot the previous kernel from the GRUB menu; it is still installed |
| Java service fails with a TLS error | Crypto policy tightened | `update-crypto-policies --show`; the partner endpoint may genuinely be too weak |
| Nginx fails to start | Config directive removed in the new version | `nginx -t` names the line |

To roll a single package back:

```bash
sudo dnf history list <package>
sudo dnf history undo <transaction-id>
```

Reboot to the previous kernel by selecting it in GRUB — patching never removes
the running kernel, precisely so this is possible.
