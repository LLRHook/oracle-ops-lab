# Runbook: OS patching of an Oracle host

**Playbook:** `ansible/playbooks/patch.yml` (`make patch`, `make patch SECURITY=1`)

## What the playbook does, and why

| Phase | Step | Why |
|---|---|---|
| Pre | free space on `/`, data, FRA | `dnf` needs room; a full FRA mid-patch turns a reboot into an outage |
| Pre | CDB and PDB `READ WRITE` | never patch a host that is already unhealthy; you lose the ability to tell what the patch broke |
| Pre | successful level 0/1 backup < 48 h old (from the textfile metric) | a kernel/libc update is a change to the platform under the database; have a restore point |
| Update | `dnf update` (or `--security`) | security-only for an emergency window; full updates on the normal cadence |
| Decide | `needs-restarting -r` | reboot only if kernel, systemd or glibc changed; most patch days end without a reboot |
| Reboot | `systemctl stop oracle-free-26ai` (shutdown immediate + listener), reboot, service returns | an orderly shutdown writes a clean checkpoint, so startup needs no crash recovery; `RequiresMountsFor` keeps the service from starting before `/u02`,`/u03`,`/u04` are mounted |
| No reboot | restart services flagged by `needs-restarting -s` (exporters, chrony, firewalld) | pick up patched libraries without touching the database |
| Post | listener `READY`, PDB open, `use_large_pages=ONLY`, huge pages in use, exporters answering | the same checks a human would do; they fail the play if anything is off |

## Running it

```bash
make patch              # all updates
make patch SECURITY=1   # security advisories only
```

Output ends with a summary: packages changed, whether a reboot happened, the running kernel,
database state and huge page counters.

## Fleets: `serial`, `max_fail_percentage`, and ordering

The play sets `serial: 1` and `max_fail_percentage: 0`: hosts are patched one at a time and
the run stops at the first failure. For a large estate you would:

- raise `serial` to a small batch (e.g. `serial: [1, 5, 20%]`: canary, then small, then
  rolling) once the first host is green;
- order the inventory so standbys/replicas go before primaries, and non-production before
  production;
- run it from a controller with `--limit` and tags, and keep the dnf transaction ids
  (`dnf history`) in the change record for rollback (`dnf history undo <id>`).

## If the post-checks fail

- Listener not `READY`: `sudo runuser -u oracle -- /opt/oracle/product/26ai/dbhomeFree/bin/lsnrctl start`.
- Instance down after reboot: see `instance-wont-start-hugepages.md` (a new kernel can shift
  how many huge pages can be carved; the role sizes with headroom but check `HugePages_Total`).
- PDB not open: `alter pluggable database FREEPDB1 open;` and check the alert log; the saved
  state (`dba_pdb_saved_states`) should open it automatically.
- Exporter down: `journalctl -u oracledb_exporter -n 50`; a glibc update is harmless (the
  binary is the glibc-2.28 build), an Oracle client library change is not.

## Rolling back

`dnf history list` then `dnf history undo <id>`; reboot again if the kernel was involved
(`grubby --set-default` to the previous kernel if the new one fails to boot). The database
itself is not touched by OS patching, so there is nothing to roll back on the Oracle side.
