# Runbook: tablespace almost full

**Alert:** `TablespaceAlmostFull` (>85 % of maximum size, TEMP/UNDO excluded)
**Severity:** warning

## What the metric measures

`oracledb_ops_tablespace_used_percent` comes from `CDB_TABLESPACE_USAGE_METRICS`, which is
*autoextend-aware*: the denominator is the size the datafiles can grow to (`maxsize`), not
their current size. 85 % therefore means real headroom is running out, not that a file is
about to autoextend (which is normal).

## Diagnose

```bash
sudo runuser -u oracle -- /usr/local/bin/oraops-sql -p FREEPDB1 "
select tablespace_name, round(used_percent,1) pct, round(used_space*8192/1048576) used_mb,
       round(tablespace_size*8192/1048576) max_mb from dba_tablespace_usage_metrics order by 2 desc;
select file_name, round(bytes/1048576) mb, autoextensible, round(maxbytes/1048576) max_mb from dba_data_files;"
df -h /u02/oradata
```

Also check what is growing: `dba_segments` by `bytes desc`, and whether it is expected
(data growth), a runaway (audit table, logging), or reclaimable (dropped objects in the
recycle bin: `purge recyclebin;`).

## Fix

1. If the datafile has a `maxsize` below what the volume can hold, raise it:
   ```sql
   alter database datafile '/u02/oradata/FREE/FREEPDB1/users01.dbf' autoextend on next 64M maxsize 4G;
   ```
2. If the volume is the limit, grow it (LVM makes this online and safe):
   add a disk/VMDK -> `pvcreate /dev/vdX` -> `vgextend vg_oradata /dev/vdX` ->
   `lvextend -l +100%FREE /dev/vg_oradata/lv_oradata` -> `xfs_growfs /u02/oradata`.
3. If growth is unexpected, involve the application owner; adding space to a runaway only
   delays the next page.

Remember the Free edition caps user data at 12 GB (`ORA-12954`); on a real edition the
limit is the storage you give it.

## Verify

`oracledb_ops_tablespace_used_percent{tablespace="..."}` back under 85; alert clears after 15 min.
