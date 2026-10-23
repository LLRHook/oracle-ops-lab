#!/usr/bin/env bash
# Pull raw runtime evidence from the VM into evidence/raw/. docs/EVIDENCE.md is curated by hand
# from these captures (trimmed, with dates and versions).
set -euo pipefail
cd "$(dirname "$0")/.."
out=evidence/raw
mkdir -p "$out"
vm=oracle-ops-lab
run() { local name=$1; shift; echo "== $name"; limactl shell "$vm" -- sudo bash -lc "$*" > "$out/$name.txt" 2>&1 || true; }

run os-release 'cat /etc/oracle-release; uname -r; getconf PAGESIZE; cat /proc/cmdline'
run meminfo-hugepages "grep -E '^(HugePages_|Hugepagesize|MemTotal|MemFree|Shmem)' /proc/meminfo; cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; cat /etc/tmpfiles.d/oracle-ops-lab-thp.conf; ipcs -m; runuser -u oracle -- /usr/local/bin/oraops-sql \"select name||'='||bytes from v\\\$sgainfo where name in ('Maximum SGA Size','Granule Size','Fixed SGA Size')\""
run sysctl 'sysctl kernel.shmmax kernel.shmall kernel.shmmni kernel.sem fs.file-max fs.aio-max-nr net.ipv4.ip_local_port_range net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max vm.nr_hugepages vm.hugetlb_shm_group kernel.panic_on_oops; cat /etc/sysctl.d/99-oracle-ai-database-preinstall-26ai-sysctl.conf /etc/sysctl.d/98-oracle-ops-lab-hugepages.conf'
run limits 'cat /etc/security/limits.d/oracle-ai-database-preinstall-26ai.conf; runuser -u oracle -- bash -c "ulimit -a"; p=$(pgrep -f "^db_pmon_FREE" | head -1); echo "pmon pid $p"; grep -E "locked|open files|processes" /proc/$p/limits'
run storage 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT; pvs; vgs; lvs; findmnt -t xfs -o TARGET,SOURCE,OPTIONS; df -h /u02/oradata /u03/redo /u04/fra; grep -E "u0[234]" /etc/fstab'
run selinux-firewall 'getenforce; sestatus | head -3; firewall-cmd --list-all'
run services 'systemctl status oracle-free-26ai node_exporter oracledb_exporter --no-pager -l | head -60; systemctl list-timers "oracle-rman*" --no-pager; systemctl cat oracle-free-26ai | head -40'
run oracle-state "cat > /tmp/evidence.sql <<'SQL'
select 'CDB '||name||' '||open_mode||' '||log_mode from v\$database;
select 'PDB '||name||' '||open_mode from v\$pdbs;
select name||'='||value from v\$parameter where name in ('sga_max_size','sga_target','pga_aggregate_target','use_large_pages','memory_target','db_recovery_file_dest','db_recovery_file_dest_size','pre_page_sga') order by 1;
select 'datafile '||name from v\$datafile;
select 'redo '||member from v\$logfile;
select 'control '||name from v\$controlfile;
select 'fra '||name||' limit='||space_limit||' used='||space_used||' reclaimable='||space_reclaimable from v\$recovery_file_dest;
select banner_full from v\$version;
SQL
chmod 644 /tmp/evidence.sql; runuser -u oracle -- /usr/local/bin/oraops-sql -f /tmp/evidence.sql; rm -f /tmp/evidence.sql"
run alert-log-largepages 'grep -n -A11 "Available system pagesizes" /opt/oracle/diag/rdbms/free/FREE/trace/alert_FREE.log | tail -12'
run rman-config 'runuser -u oracle -- bash -c "export ORACLE_HOME=/opt/oracle/product/26ai/dbhomeFree ORACLE_SID=FREE; \$ORACLE_HOME/bin/rman target / <<< \"SHOW ALL; LIST BACKUP SUMMARY; REPORT OBSOLETE;\""'
run rman-logs 'ls -la /var/log/oracle-rman/; cat /var/lib/node_exporter/textfile_collector/oracle_rman_backup.prom'
run node-exporter-metrics 'curl -s localhost:9100/metrics | grep -E "^(node_memory_HugePages|node_memory_Hugepagesize|oracle_rman_|node_filesystem_avail_bytes.*u0[234]|node_systemd_unit_state.*oracle-free.*active)"'
run oracledb-exporter-metrics 'curl -s localhost:9161/metrics | grep -E "^(oracledb_up|oracledb_ops_|oracledb_sessions_value|oracledb_tablespace_bytes|oracledb_db_system)" | head -60'
run preinstall-log 'cat /var/log/oracle-ai-database-preinstall-26ai/results/orakernel.log | head -80'
run configure-log 'sed -n 1,60p /var/log/oracle-ops-lab/configure.log; grep -c . /var/log/oracle-ops-lab/configure.log'
run vendor-script-fix 'grep -n -- "-c \"\$1\"\|-c \"\$DBCA_CLI\"" /etc/init.d/oracle-free-26ai'
run drill-logs "ls -la /var/log/oracle-rman/ | grep drill; runuser -u oracle -- /usr/local/bin/oraops-sql -p FREEPDB1 \"select phase||'='||count(*) from drill.marker group by phase\""
run packages 'rpm -q oracle-ai-database-preinstall-26ai oracle-ai-database-free-26ai chrony firewalld lvm2 xfsprogs; rpm -qa "kernel-uek-core*" | sort; dnf history list | head -8'
echo "evidence collected in $out/"
