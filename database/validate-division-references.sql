do $$declare r record;begin
 for r in select n.nspname s,c.relname t,con.conname from pg_constraint con join pg_class c on c.oid=con.conrelid join pg_namespace n on n.oid=c.relnamespace where con.confrelid='public.divisions'::regclass and not con.convalidated loop
  execute format('alter table %I.%I validate constraint %I',r.s,r.t,r.conname);
 end loop;
end $$;
