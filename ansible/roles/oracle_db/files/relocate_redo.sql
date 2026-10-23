-- Move all online redo log groups to the dedicated redo volume.
-- Arguments: &1 = redo directory, &2 = size in MB, &3 = number of groups.
-- Strategy: add the new groups, then cycle through the old ones, switching and
-- checkpointing until each is INACTIVE (and archived), then drop it. The OS files of the
-- dropped groups are removed afterwards by Ansible.
set serveroutput on
declare
  l_dir    varchar2(400) := '&1';
  l_size   number        := &2;
  l_count  number        := &3;
  l_max    number;
  l_status varchar2(16);
  l_tries  number;
begin
  select max(group#) into l_max from v$log;
  for i in 1 .. l_count loop
    execute immediate 'alter database add logfile group ' || (l_max + i) ||
      ' (''' || l_dir || '/redo' || to_char(l_max + i, 'FM09') || '.log'') size ' || l_size || 'M';
    dbms_output.put_line('added group ' || (l_max + i));
  end loop;
  for g in (select distinct l.group# from v$log l join v$logfile f on f.group# = l.group#
            where f.member not like l_dir || '/%' order by 1) loop
    l_tries := 0;
    loop
      select status into l_status from v$log where group# = g.group#;
      exit when l_status in ('INACTIVE', 'UNUSED');
      execute immediate 'alter system switch logfile';
      execute immediate 'alter system checkpoint';
      dbms_session.sleep(2);
      l_tries := l_tries + 1;
      if l_tries > 30 then
        raise_application_error(-20001, 'group ' || g.group# || ' never became INACTIVE');
      end if;
    end loop;
    execute immediate 'alter database drop logfile group ' || g.group#;
    dbms_output.put_line('dropped group ' || g.group#);
  end loop;
end;
/
