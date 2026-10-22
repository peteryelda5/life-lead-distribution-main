-- Isolated fixtures only. All changes, including audit/notification events, roll back.
begin;
do $$
declare a uuid; other_agent uuid; master_id uuid; div text; lid uuid; chat_lid uuid; admin_lid uuid;
 deal uuid; sid uuid:=gen_random_uuid(); folder text:='__closed_lead_test_'||gen_random_uuid(); result jsonb; denied boolean;
begin
 select p.id,p.division into a,div from public.profiles p join public.divisions d on d.id=p.division where p.active and not coalesce(p.archived,false) and p.role='agent' and p.division='vivid_life' and not d.archived limit 1;
 select id into other_agent from public.profiles where active and not coalesce(archived,false) and role='agent' and id<>a limit 1;
 select id into master_id from public.profiles where active and is_super_admin limit 1;
 if a is null or other_agent is null or master_id is null then raise exception 'Test accounts unavailable';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'aal','aal2','session_id',sid)::text,true);
 insert into public.leads(first_name,last_name,phone,division,status,assigned_to,lead_type,state,csv_headers,csv_values)
 values('Lifecycle','Fixture','2025550100',div,'assigned',a,folder,'MI','[]','[]') returning id into lid;
 insert into public.leads(first_name,last_name,phone,division,status,assigned_to,lead_type,state,csv_headers,csv_values)
 values('Chat','Fixture','2025550101',div,'assigned',a,folder,'MI','[]','[]') returning id into chat_lid;
 insert into public.leads(first_name,last_name,phone,division,status,assigned_to,lead_type,state,csv_headers,csv_values)
 values('Admin','Fixture','2025550102',(select division from public.profiles where id=master_id),'assigned',master_id,folder,'MI','[]','[]') returning id into admin_lid;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',other_agent,'aal','aal2','session_id',sid)::text,true);
 set local role authenticated;
 denied:=false;begin perform public.close_lead(lid,'Ethos','Term',100,current_date);exception when others then denied:=true;end;
 if not denied then raise exception 'Another agent closed the lead';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 set local role authenticated;
 deal:=public.close_lead(lid,'Ethos','Term',100,current_date);
 result:=public.my_assigned_leads_filtered('',folder,true,1,500,array['MI']);
 if (result->>'count')::int<>1 or exists(select 1 from jsonb_array_elements(result->'data') r where r->>'id'=lid::text) then raise exception 'Closed lead remains in My Leads';end if;
 if (select lead_count from public.my_lead_folders() where lead_type=folder)<>1 then raise exception 'Folder count includes closed lead';end if;
 reset role;
 denied:=false;begin perform public.dialer_lead_phone(a,lid);exception when others then if sqlerrm not like 'Lead is unavailable%' then raise;end if;denied:=true;end;
 set local role authenticated;
 if not denied then raise exception 'Closed lead is callable';end if;
 denied:=false;begin perform public.close_lead(lid,'Ethos','Term',100,current_date);exception when others then denied:=true;end;
 if not denied then raise exception 'Duplicate close accepted';end if;
 perform public.chat_close_deal(chat_lid,'Ethos','Term',100,current_date);
 result:=public.my_assigned_leads_filtered('',folder,true,1,500,array['MI']);
 if (result->>'count')::int<>0 then raise exception 'Chat-linked close stays in My Leads';end if;
 reset role;
 if (select status from public.leads where id=lid)<>'closed' or not exists(select 1 from public.closed_business where id=deal and lead_id=lid and agent_id=a) then raise exception 'Close not persisted';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'aal','aal2','session_id',sid)::text,true);
 set local role authenticated;
 perform public.close_lead(admin_lid,'Ethos','Term',100,current_date);
 perform public.remove_closed_deal(deal);
 reset role;
 if (select status from public.leads where id=lid)<>'assigned' then raise exception 'Removing a deal did not reopen its lead';end if;
 if (select status from public.leads where id=admin_lid)<>'closed' then raise exception 'Admin personal lead failed to close';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2','session_id',sid)::text,true);
 set local role authenticated;
 result:=public.my_assigned_leads_filtered('',folder,true,1,500,array['MI']);
 if (result->>'count')::int<>1 then raise exception 'Reopened lead missing';end if;
 perform public.chat_standalone_deal(div,a,gen_random_uuid(),'Ethos','Term',100,current_date);
 result:=public.my_assigned_leads_filtered('',folder,true,1,500,array['MI']);
 if (result->>'count')::int<>1 then raise exception 'Unlinked deal changed an unrelated lead';end if;
 reset role;
end;$$;
select 'PASS: agent/admin/chat close, folder/state list exclusion, duplicate prevention, foreign-agent denial, removal reopens, unlinked deals preserve leads' result;
rollback;
