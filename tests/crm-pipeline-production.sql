begin;
do $$
declare actor uuid; sid uuid:=gen_random_uuid(); fresh uuid:=gen_random_uuid(); sibling uuid:=gen_random_uuid(); c private.book_crm_clients; linked private.book_crm_records; old_deal jsonb; n bigint; stage text; version timestamptz; person uuid;
begin
 select id into actor from public.profiles where role='admin' and is_super_admin and active and not archived limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated','aal','aal2','session_id',sid)::text,true);
 insert into private.book_unlocks(user_id,session_id,expires_at) values(actor,sid::text,now()+interval '15 minutes');
 select count(*) into n from public.closed_business;
 perform public.book_crm_save_v2(fresh,jsonb_build_object('client_name','Rollback Pipeline Test','phone','2025550100','carrier','Ethos','policy_type','Term','monthly_payment',81.12,'application_date',current_date,'effective_date',current_date,'pipeline_stage','approved'),null,null);
 foreach stage in array array['in_force','approved','in_force','chargeback','cancelled','in_force'] loop
  select updated_at into version from private.book_crm_clients where id=fresh;
  perform set_config('role','authenticated',true);
  perform public.book_crm_save_v2(fresh,jsonb_build_object('pipeline_stage',stage),version,null);
  perform set_config('role','postgres',true);
  select * into c from private.book_crm_clients where id=fresh;
  if c.pipeline_stage<>stage or c.status<>'draft' or c.deal_id is not null or c.production_recorded or (select count(*) from public.closed_business)<>n then raise exception 'Pipeline reported production';end if;
 end loop;
 person:=c.profile_id;
 perform public.book_crm_policy_save(person,sibling,jsonb_build_object('carrier','Aetna','policy_type','Final Expense','monthly_payment',19.99,'application_date',current_date,'effective_date',current_date,'pipeline_stage','in_force'),null,null);
 if (select count(*) from public.closed_business)<>n or exists(select 1 from private.book_crm_clients where id=sibling and (deal_id is not null or production_recorded)) then raise exception 'Adding In force policy created production';end if;
 select r.* into linked from private.book_crm_records r where r.deal_id is not null and private.book_crm_can_access(r.agent_id,r.deal_id) limit 1;
 if linked.id is null then raise exception 'Missing linked fixture';end if;
 select to_jsonb(d) into old_deal from public.closed_business d where id=linked.deal_id;
 foreach stage in array array['approved','in_force','chargeback'] loop
  select updated_at into version from private.book_crm_clients where id=linked.id;
  perform public.book_crm_save_v2(linked.id,jsonb_build_object('pipeline_stage',stage,'effective_date',current_date),version,linked.deal_version);
  if (select to_jsonb(d) from public.closed_business d where id=linked.deal_id) is distinct from old_deal then raise exception 'Stage changed recorded deal';end if;
  if (select status from private.book_crm_clients where id=linked.id) is distinct from linked.status then raise exception 'Stage changed production status';end if;
 end loop;
 begin
  perform public.book_crm_save_v2(fresh,'{"pipeline_stage":"approved"}',version-interval '1 day',null);
  raise exception 'Stale edit accepted';
 exception when sqlstate 'PT409' then null;end;
end $$;
rollback;
