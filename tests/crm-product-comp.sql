-- Actual RPC checks using synthetic rates, never the source-image percentages.
-- Every test policy, grid row, snapshot, audit entry and event rolls back.
begin;
do $$
declare
 owner_id uuid; v_agent_id uuid; admin_id uuid; sid uuid:=gen_random_uuid();
 one uuid:=gen_random_uuid(); two uuid:=gen_random_uuid(); r jsonb; denied boolean;
begin
 select id into owner_id from public.profiles where active and is_super_admin limit 1;
 select p.id into v_agent_id from public.profiles p join public.divisions d on d.id=p.division
 where p.active and p.role='agent' and not coalesce(p.archived,false) and not d.archived and p.division='vivid_life' limit 1;
 select id into admin_id from public.profiles where active and role='admin' and not is_super_admin and not coalesce(archived,false) limit 1;
 if owner_id is null or v_agent_id is null or admin_id is null then raise exception 'Active test roles missing';end if;
 insert into private.book_unlocks values
 (owner_id,sid::text,now()+interval '15 minutes'),(v_agent_id,sid::text,now()+interval '15 minutes'),(admin_id,sid::text,now()+interval '15 minutes');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'aal','aal2','session_id',sid)::text,true);
 perform public.book_grid('save',v_agent_id,'Ethos','TruStage Advantage Whole Life',92.5,70,current_date);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_agent_id,'aal','aal2','session_id',sid)::text,true);
 perform public.book_crm_save_v2(one,jsonb_build_object('agent_id',v_agent_id,'client_name','__PRODUCT_COMP_TEST__','phone','2025550111','carrier','Ethos','policy_type','TruStage Advantage Whole Life','monthly_payment',100,'application_date',current_date,'effective_date',current_date,'pipeline_stage','in_force'));
 r:=public.book_crm_profile_detail(one)->'client';
 if (r->>'estimated_advance')::numeric is distinct from 777::numeric then raise exception 'Exact product rate must price 100/month at 92.5%% comp and 70%% advance: %',r->>'estimated_advance';end if;
 perform public.book_crm_policy_save(one,two,jsonb_build_object('carrier','Ethos','policy_type','Ethos Term Life – Prime','monthly_payment',100,'application_date',current_date,'effective_date',current_date,'pipeline_stage','in_force'));
 r:=public.book_crm_profile_detail(two)->'client';
 if r->>'estimated_advance' is not null then raise exception 'Different product inherited a rate';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'aal','aal2','session_id',sid)::text,true);
 perform public.book_grid('save',v_agent_id,'Ethos','Ethos Term Life – Prime',110,80,current_date+1);
 r:=public.book_crm_profile_detail(two)->'client';
 if r->>'estimated_advance' is not null then raise exception 'Future-effective rate applied early';end if;
 perform public.book_grid('save',v_agent_id,'Ethos','TruStage Advantage Whole Life',100,80,current_date);
 r:=public.book_crm_profile_detail(one)->'client';
 if (r->>'estimated_advance')::numeric is distinct from 777::numeric then raise exception 'Previously priced policy snapshot changed';end if;
 perform public.book_grid('save',v_agent_id,'Ethos','Ethos Term Life – Prime',80,75,current_date);
 r:=public.book_crm_profile_detail(two)->'client';
 if (r->>'estimated_advance')::numeric is distinct from 720::numeric then raise exception 'Unpriced policy did not receive its own matching rate';end if;
 if (select count(*) from private.book_comp_grid where agent_id=v_agent_id and carrier='ethos' and policy_type='ethos term life – prime' and effective_date in(current_date,current_date+1))<2 then raise exception 'Effective-date history lost';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_agent_id,'aal','aal2','session_id',sid)::text,true);
 denied:=false;begin perform public.book_grid('save',v_agent_id,'Ethos','TruStage Advantage Whole Life',150,90,current_date);exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'Agent wrote compensation';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'aal','aal2','session_id',sid)::text,true);
 denied:=false;begin perform public.book_grid('save',v_agent_id,'Ethos','TruStage Advantage Whole Life',150,90,current_date);exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'Agency admin wrote compensation';end if;
end;$$;
select 'PASS: exact product matching, correct estimate, product isolation, future effective dates, saved snapshots, unpriced backfill, history and owner-only rate editing; rolled back' result;
rollback;
