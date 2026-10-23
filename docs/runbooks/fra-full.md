# Runbook: Fast Recovery Area almost full / full

**Alerts:** `FRAAlmostFull` (>85 % net), `FRAFull` (>95 % net)
**Severity:** warning / critical

## Why it matters

In ARCHIVELOG mode every filled online redo log must be archived into the FRA before it
can be reused. When the FRA hits `db_recovery_file_dest_size` and nothing is reclaimable,
the archiver (ARCn) stalls, the instance cannot switch logs, and **every session that
needs to write redo hangs** with `ORA-00257: Archiver error` or `ORA-19809/ORA-19815` in
the alert log. The database looks "up" but does nothing. This is the single most common
self-inflicted Oracle outage.

The metric is **net of reclaimable space**: Oracle deletes files it knows are obsolete
(backed-up archived logs under the deletion policy, expired backup pieces) on its own
when it needs room. Reclaimable space is not a problem; non-reclaimable space is.

## Diagnose

```bash
sudo runuser -u oracle -- /usr/local/bin/oraops-sql "
select name, round(space_limit/1048576) limit_mb, round(space_used/1048576) used_mb,
       round(space_reclaimable/1048576) reclaimable_mb, number_of_files from v\$recovery_file_dest;
select file_type, percent_space_used, percent_space_reclaimable, number_of_files from v\$recovery_area_usage;"
df -h /u04/fra
tail -30 /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log
```

`v$recovery_area_usage` tells you *what* is eating the space: archived logs that have not
been backed up (backup job broken?), backup pieces beyond the retention window (DELETE
OBSOLETE not running?), flashback logs, or a runaway workload generating redo.

## Fix, in order of preference

1. **Make the backups current.** Archived logs become reclaimable once backed up:
   ```bash
   make backup LEVEL=archivelog        # or: sudo systemctl start oracle-rman-backup@archivelog.service
   ```
   Then let Oracle reclaim, or force it: `DELETE NOPROMPT ARCHIVELOG ALL BACKED UP 1 TIMES TO DISK;` in RMAN.
2. **Remove obsolete backups** (should already be done by every scheduled run):
   ```
   rman target /
   CROSSCHECK BACKUP; CROSSCHECK ARCHIVELOG ALL;
   DELETE NOPROMPT EXPIRED BACKUP; DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
   DELETE NOPROMPT OBSOLETE;
   ```
3. **Raise the quota temporarily** if the volume has room (`df -h /u04/fra`):
   ```sql
   alter system set db_recovery_file_dest_size=18G scope=both;
   ```
   This unblocks the archiver immediately. Put the value back (or change
   `oracle_fra_size_mb` and re-converge) once the cause is fixed; a quota that silently
   grows defeats the point of having one.
4. **Grow the volume** (production): add a VMDK / extend the LUN, `pvcreate`, `vgextend vg_fra`,
   `lvextend -l +100%FREE /dev/vg_fra/lv_fra`, `xfs_growfs /u04/fra`, then raise the quota.

Never `rm` files inside the FRA by hand. Oracle tracks them in the control file; deleting
behind its back leaves "expired" entries and the space is not even reclaimed until a
CROSSCHECK. If you must, follow with `CROSSCHECK ... ; DELETE EXPIRED ...;`.

## Verify

`oracledb_ops_fra_used_percent_net` below 85 on `:9161/metrics`; `alter system switch logfile;`
completes immediately; no new `ORA-00257` in the alert log.

## Break/fix exercise

Fill the FRA with archived redo that cannot be reclaimed, watch sessions hang, then recover:

```bash
# shrink the quota so it fills fast, generate redo, watch
sudo runuser -u oracle -- /usr/local/bin/oraops-sql "alter system set db_recovery_file_dest_size=600M scope=both"
sudo runuser -u oracle -- /usr/local/bin/oraops-sql -p FREEPDB1 "
create table fra_filler as select rpad('x',4000,'x') c from dual connect by level <= 20000;
insert into fra_filler select * from fra_filler; commit; insert into fra_filler select * from fra_filler; commit;"
# the second insert may hang once the FRA is full: ORA-00257 in the alert log. Recover:
make backup LEVEL=archivelog
sudo runuser -u oracle -- /usr/local/bin/oraops-sql "alter system set db_recovery_file_dest_size=15360M scope=both"
sudo runuser -u oracle -- /usr/local/bin/oraops-sql -p FREEPDB1 "drop table fra_filler purge"
```
