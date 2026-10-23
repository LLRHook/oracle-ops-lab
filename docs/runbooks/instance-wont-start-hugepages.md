# Runbook: instance will not start after a reboot (huge pages)

**Alerts:** `DatabaseDown`, `HugePagesPoolMissing`, `HugePagesNotInUse`
**Severity:** critical (database down) / warning (pool missing while DB still up)

## Symptom

After a reboot (patching, power event, VM migration) `systemctl status oracle-free-26ai`
shows the listener running but the instance down, and the alert log ends with:

```
ORA-27137: unable to allocate large pages to create a shared memory segment
```

or the "Large Pages Information" block in `alert_FREE.log` reports fewer pages
available than the SGA needs.

## Why this happens

The instance runs with `use_large_pages=ONLY`: it refuses to start unless the whole SGA
(`sga_max_size`, 1536 MiB here) fits in the kernel's huge page pool. That is deliberate.
The alternative, `AUTO`/`TRUE`, silently falls back to 4 KiB pages and the database
runs slower with a much bigger page-table footprint; nobody notices until a bad day.
`ONLY` turns a silent degradation into a loud, immediate failure at start time.

The pool is sized at boot from `vm.nr_hugepages` (`/etc/sysctl.d/98-oracle-ops-lab-hugepages.conf`).
It can be short because:

1. the sysctl file was removed or edited (fleet drift, a restore from an older image);
2. memory was fragmented when sysctl ran late in boot and the kernel could not carve out
   all pages (`HugePages_Total` < `vm.nr_hugepages`);
3. the SGA was raised (`sga_max_size`) without resizing the pool;
4. the VM was given less RAM than before (VMware reservation changed), or the host is
   over-committed and `HugePages_Total` could not be satisfied;
5. `memlock` limits for `oracle` were lowered below the SGA size (`ulimit -l`).

## Diagnose (2 minutes)

```bash
grep -E 'HugePages_(Total|Free|Rsvd)|Hugepagesize' /proc/meminfo
sysctl vm.nr_hugepages
cat /etc/sysctl.d/98-oracle-ops-lab-hugepages.conf
sudo runuser -u oracle -- bash -c 'ulimit -l'           # must be >= SGA in kB
sudo runuser -u oracle -- /usr/local/bin/oraops-sql "select value from v\$parameter where name='sga_max_size'"  # only if instance is up
grep -A8 'Large Page' /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log | tail -20
```

Rule of thumb: `HugePages_Total * Hugepagesize` must be >= `sga_max_size` plus a few
pages of headroom (the role uses 16).

## Fix

**Preferred: re-converge the host.** The os_prereqs role recomputes the pool from the
configured SGA and the live `Hugepagesize`, reapplies the sysctl and asserts the kernel
honoured it:

```bash
make deploy ARGS="--tags os_prereqs,oracle_db"
```

**Manual, if Ansible is not at hand:**

```bash
# 1. restore the pool (784 pages x 2 MiB for a 1536 MiB SGA on this host)
echo 'vm.nr_hugepages = 784' | sudo tee /etc/sysctl.d/98-oracle-ops-lab-hugepages.conf
sudo sysctl --system
grep HugePages_Total /proc/meminfo      # if it is still short, memory is fragmented: reboot once
# 2. start the service
sudo systemctl start oracle-free-26ai
# 3. confirm the SGA landed in huge pages
grep -E 'HugePages_(Total|Free|Rsvd)' /proc/meminfo
```

If the pool cannot be made large enough on this host (RAM was reduced), the only safe
options are to lower `sga_max_size`/`sga_target` in the spfile *and* the `oracle_sga_mb`
variable, then re-converge; or give the VM its memory back. Do **not** change
`use_large_pages` to `AUTO` to "get it up"; that hides the problem and the alert
`HugePagesNotInUse` will fire anyway.

## Verify

- `systemctl is-active oracle-free-26ai` is `active`
- `HugePages_Free` dropped by roughly `sga_max_size / Hugepagesize` after the start
- `oracledb_up{database="default"} 1` on `:9161/metrics`, `node_memory_HugePages_Total` on `:9100/metrics`
- `make test` passes

## Break/fix exercise

Shrink the pool and watch the instance refuse to start:

```bash
sudo systemctl stop oracle-free-26ai
sudo sysctl -w vm.nr_hugepages=100
sudo systemctl start oracle-free-26ai        # fails
tail -5 /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log   # ORA-27137
sudo sysctl --system && sudo systemctl start oracle-free-26ai   # recovers
```
