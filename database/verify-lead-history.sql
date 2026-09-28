do $$
declare m uuid; a uuid; lid uuid; before_count bigint; rows jsonb; denied boolean;
begin
 select id into m from public.profiles where is_super_admin and active;
 select id into a from public.profiles where role='admin' and division='legacy_life' and active limit 1;
 select count(*) into before_count from public.lead_history_events;
 begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 insert into public.leads(first_name,last_name,division) values('History','Fixture','owner') returning id into lid;
 update public.leads set call_notes='Private fixture note' where id=lid;
 rows:=public.lead_history_page('owner',lid,null);
 if jsonb_array_length(rows)<>2 or rows->0->>'action'<>'changed' or not (rows->0->'changed_fields') ? 'call_notes' or rows::text like '%Private fixture note%' then raise exception 'History capture invalid';end if;
 denied:=false;begin delete from public.lead_history_events where lead_id=lid;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'History can be deleted';end if;
 perform public.send_leads_to_division(array[lid],'owner','legacy_life');
 delete from public.leads where id=lid;
 rows:=public.lead_history_page('legacy_life',lid,null);
 if jsonb_array_length(rows)<>2 or rows->0->>'action'<>'deleted' or rows->1->>'action'<>'division_transfer' then raise exception 'Transfer/delete history invalid';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 denied:=false;begin perform public.lead_history_page('owner',lid,null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'History division leak';end if;
 if exists(select 1 from public.lead_history_events where lead_id=lid and division='owner') then raise exception 'History table division leak';end if;
 perform public.lead_history_page('legacy_life',lid,null);
 reset role;
 raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;
 end;
 reset role;
 if (select count(*) from public.lead_history_events)<>before_count then raise exception 'Fixtures persisted';end if;
 if has_function_privilege('anon','public.lead_history_page(text,uuid,bigint)','execute') then raise exception 'Anon history access';end if;
end $$;
