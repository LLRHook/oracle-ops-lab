# Runbook: backup failed / backup too old

**Alerts:** `BackupTooOld` (no successful level 0/1 in 26 h), `ArchivelogBackupTooOld` (>3 h),
`BackupFailed` (last run of a level failed), `BackupMetricMissing` (no metric at all)
**Severity:** critical / warning

## Why freshness, not failure, is the key alert

A job that fails pages you; a job that never runs does not. `BackupTooOld` is computed from
`oracle_rman_backup_last_success_timestamp_seconds`, which the wrapper only advances on a
clean run. It therefore covers all of: RMAN errors, a stopped timer, a host rebuilt from an
old template, a wrapper that cannot write the metric file, node_exporter not picking up the
textfile directory. `BackupFailed` is the fast, specific signal; `BackupTooOld` is the one
that is allowed to wake someone up.

## Diagnose

```bash
systemctl list-timers 'oracle-rman-backup@*'               # next/last run per level
systemctl status oracle-rman-backup@level1.service          # last result
journalctl -u 'oracle-rman-backup@*' --since '-2 days' -o cat
ls -lt /var/log/oracle-rman | head                           # one log per run
grep -E '^(RMAN|ORA)-' /var/log/oracle-rman/rman-level1-*.log | tail
cat /var/lib/node_exporter/textfile_collector/oracle_rman_backup.prom
curl -s localhost:9100/metrics | grep oracle_rman_backup
```

Common causes and their signatures:

| Signature in the log | Cause | Fix |
|---|---|---|
| `ORA-19809 / ORA-19804 limit exceeded for recovery files` | FRA full | see `fra-full.md` |
| `ORA-01034 ORACLE not available` | instance down during the run | fix the instance, re-run |
| `RMAN-06059 expected archived log not found` | archived log deleted by hand | `CROSSCHECK ARCHIVELOG ALL; DELETE EXPIRED ARCHIVELOG ALL;` then re-run |
| `RMAN-03009 ... ORA-27037 unable to obtain file status` | backup piece removed outside RMAN | `CROSSCHECK BACKUP; DELETE EXPIRED BACKUP;` |
| timer `inactive`, no runs | timer disabled/host rebuilt | `make deploy ARGS="--tags backup"` |
| metric missing but logs show success | textfile dir perms / node_exporter restart | check `ls -ld /var/lib/node_exporter/textfile_collector` (root:oinstall 0775) |

## Fix

1. Correct the underlying cause from the table above.
2. Re-run the failed level now, through the unit so the metric is updated the same way:
   ```bash
   make backup LEVEL=level1          # or level0 / archivelog
   ```
3. If the level 0 is older than the recovery window (7 days), run `make backup LEVEL=level0`
   so incremental chains stay short; `RESTORE DATABASE VALIDATE` (`make drill`) proves the
   result is restorable.

## Verify

`oracle_rman_backup_last_status{level="..."} 1` and a fresh
`oracle_rman_backup_last_success_timestamp_seconds`; `LIST BACKUP SUMMARY` in RMAN shows the
new set; alert clears after the `for:` window.

## Notes for a fleet

- Keep the alert threshold just above the schedule: daily level 1 at 01:00 plus jitter means
  26 h is the earliest honest "too old"; the archivelog threshold (3 h) is the real RPO alarm.
- The `.prom` file is rendered from `/var/lib/oracle-rman/*.env`; it is safe to delete the
  `.env` of a level you have retired, the next run re-renders the file.
