# Disaster recovery drill records

Each drill run by `ansible/playbooks/dr-drill.yml` writes an evidence file here,
named `drill-<timestamp>.yml`, recording the measured recovery point and recovery
time against the stated objectives.

These files are committed. The point of a drill is the record it leaves: a claim
that "DR works" is worth nothing without a dated measurement behind it, and a
sequence of them shows whether the capability is improving or decaying.

A drill that fails its objective is still a successful drill — it found the
problem before the problem found the platform.
