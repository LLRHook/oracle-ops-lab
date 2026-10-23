# Runbook: restore a lost or corrupt datafile

**Alerts:** `PdbNotOpen`, `DatabaseDown`; or users report `ORA-01116 / ORA-01110 / ORA-01157`
**Severity:** critical

## Symptom

```
ORA-01157: cannot identify/lock data file 12 - see DBWR trace file
ORA-01110: data file 12: '/u02/oradata/FREE/FREEPDB1/users01.dbf'
```

on PDB open, instance open, or while a session touches the tablespace. The file was
deleted, the volume disappeared, or blocks are corrupt (`ORA-01578`).

## What you are relying on

- ARCHIVELOG mode: every change since the backup is in archived/online redo on `/u03/redo`
  and the FRA, so recovery is to the moment of failure, not to the last backup.
- A level 0/1 backup of the file in the FRA (`make backup`), with control file autobackup.
- The same procedure `make drill` executes end to end, with timings, every time you run it.
  Run the drill before you need this page.

## Procedure (single datafile, PDB stays closed or the tablespace offline)

1. Identify the file and whether the rest of the PDB can stay open:
   ```bash
   sudo runuser -u oracle -- /usr/local/bin/oraops-sql "
   select file#, name, status, error from v\$datafile_header where error is not null or status <> 'ONLINE';"
   ```
2. If the PDB is open and only this tablespace is affected, take the file offline so the
   rest keeps serving (ARCHIVELOG mode allows `offline` without `drop`):
   ```sql
   -- inside the PDB
   alter database datafile 12 offline;
   ```
   If the PDB failed to open, leave it closed (MOUNTED); RMAN can restore into a closed PDB.
3. Restore and recover with RMAN (as `oracle`, `rman target /`):
   ```
   RUN {
     RESTORE DATAFILE 12;
     RECOVER DATAFILE 12;
   }
   ```
   RMAN picks the most recent level 0 + level 1s, then applies archived and online redo.
   If the original location is gone, add `SET NEWNAME FOR DATAFILE 12 TO '/u02/oradata/.../users01.dbf';`
   before `RESTORE` and `SWITCH DATAFILE ALL;` after it.
4. Bring it back:
   ```sql
   alter database datafile 12 online;            -- if you took it offline in step 2
   alter pluggable database FREEPDB1 open;        -- if the PDB was closed
   ```
5. Verify application data (the drill checks marker rows; in production, let the owning
   team run their smoke test) and check `v$datafile_header` is clean.

Time it. The drill report in `docs/drills/` is the baseline RTO for this size of file; a
restore of the whole data volume scales roughly with bytes restored plus redo applied.

## If the backup itself is unusable

- `RESTORE ... VALIDATE` failing or `RMAN-06023 no backup or copy of datafile`: the file was
  never backed up (added after the last level 0 and `BACKUP OPTIMIZATION` did not cover it?)
  or the piece is gone. Try `RESTORE DATAFILE 12 FROM TAG 'LEVEL0'` with an older set, or
  `LIST BACKUP OF DATAFILE 12` to see what exists.
- Nothing usable: the data in that tablespace since its creation is lost unless the
  file can be recovered at the storage layer (VM snapshot, array snapshot, replica). This
  is why the backup-freshness alert exists.

## Prevention

- `make drill` regularly; keep the reports.
- Keep `/u02/oradata` and `/u04/fra` on separate devices (they are): a lost data volume
  must not take the backups with it. In production, replicate the FRA off-host.
