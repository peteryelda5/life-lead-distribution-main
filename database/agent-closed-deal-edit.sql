CREATE OR REPLACE FUNCTION public.correct_closed_lead(p_deal_id uuid, p_expected_updated_at timestamp with time zone, p_fields jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.closed_business%rowtype; l public.leads%rowtype; changed public.leads%rowtype;
 new_first text; new_last text; new_csv jsonb;
begin
 if not private.verified_portal_session() then raise exception 'Two-step verification required' using errcode='42501';end if;
 if p_fields is null or jsonb_typeof(p_fields)<>'object' or p_fields='{}'::jsonb or exists
 (select 1 from jsonb_object_keys(p_fields) k where k<>all(array[
 'first_name','last_name','phone','email','state','source','notes','lead_type','csv_values'])) then
  raise exception 'Invalid correction fields' using errcode='22023';
 end if;
 if length(btrim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then
  raise exception 'Enter a correction reason (3–500 characters)' using errcode='22023';
 end if;
 select * into d from public.closed_business where id=p_deal_id;
 if not found or d.lead_id is null then raise exception 'This deal has no linked lead to correct' using errcode='22023';end if;
 select * into l from public.leads where id=d.lead_id for update;
 if not found or l.status<>'closed' then raise exception 'The original closed lead is unavailable' using errcode='22023';end if;
 if not (d.agent_id=auth.uid() or (exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active and not coalesce(p.archived,false)) and coalesce(l.division=any(private.my_admin_divisions()),false))) then
  raise exception 'You cannot correct this closed lead' using errcode='42501';
 end if;
 if l.updated_at is distinct from p_expected_updated_at then
  raise sqlstate 'PT409' using message='Lead changed since you opened it. Reopen the deal and try again.';
 end if;
 new_first:=case when p_fields?'first_name' then btrim(p_fields->>'first_name') else l.first_name end;
 new_last:=case when p_fields?'last_name' then btrim(p_fields->>'last_name') else l.last_name end;
 if nullif(new_first,'') is null or nullif(new_last,'') is null or length(new_first)>250 or length(new_last)>250 then
  raise exception 'First and last name are required (up to 250 characters)' using errcode='22023';end if;
 new_csv:=case when p_fields?'csv_values' then p_fields->'csv_values' else l.csv_values end;
 if jsonb_typeof(new_csv)<>'array' or jsonb_array_length(new_csv)<>jsonb_array_length(l.csv_headers) or
   pg_column_size(new_csv)>1048576 or exists(select 1 from jsonb_array_elements(new_csv) v where jsonb_typeof(v)<>'string') then
   raise exception 'Uploaded values must match the original columns' using errcode='22023';end if;
 perform set_config('lld.correction_reason',btrim(p_reason),true);
 update public.leads set first_name=new_first,last_name=new_last,
  phone=case when p_fields?'phone' then nullif(btrim(p_fields->>'phone'),'') else l.phone end,
  email=case when p_fields?'email' then nullif(btrim(p_fields->>'email'),'') else l.email end,
  state=case when p_fields?'state' then nullif(btrim(p_fields->>'state'),'') else l.state end,
  source=case when p_fields?'source' then nullif(btrim(p_fields->>'source'),'') else l.source end,
  notes=case when p_fields?'notes' then nullif(btrim(p_fields->>'notes'),'') else l.notes end,
  lead_type=case when p_fields?'lead_type' then nullif(btrim(p_fields->>'lead_type'),'') else l.lead_type end,
  csv_values=new_csv
 where id=l.id returning * into changed;
 if (l.first_name,l.last_name,l.phone,l.email,l.state,l.source,l.notes,l.lead_type,l.csv_values) is not distinct from
 (changed.first_name,changed.last_name,changed.phone,changed.email,changed.state,changed.source,changed.notes,changed.lead_type,changed.csv_values) then
  return jsonb_build_object('changed',false,'lead_id',l.id);
 end if;
 return jsonb_build_object('changed',true,'lead_id',l.id,'updated_at',changed.updated_at);
end $function$;

create function private.correct_closed_deal(p_deal_id uuid,p_expected jsonb,p_fields jsonb,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.closed_business%rowtype; before_fields jsonb; changed public.closed_business%rowtype; premium numeric; date_value date;
begin
 if not private.verified_portal_session() then raise exception 'Verified sign-in required' using errcode='42501';end if;
 select * into d from public.closed_business where id=p_deal_id for update;
 if not found or not (d.agent_id=auth.uid() or public.is_super_admin() or public.admin_can_manage_agent(d.agent_id) or private.can_read_admin_sale(d.agent_id,d.lead_id)) then raise exception 'You can edit only your own or authorized agency deals' using errcode='42501';end if;
 if p_fields is null or jsonb_typeof(p_fields)<>'object' or exists(select 1 from jsonb_object_keys(p_fields)k where k<>all(array['carrier','policy_type','monthly_premium','application_date','policy_number','notes'])) then raise exception 'Invalid deal fields';end if;
 before_fields:=jsonb_build_object('carrier',d.carrier,'policy_type',d.policy_type,'monthly_premium',d.monthly_premium,'application_date',d.application_date,'policy_number',d.policy_number,'notes',d.notes);
 if p_expected is distinct from before_fields then raise sqlstate 'PT409' using message='This deal changed since you opened it. Reopen it and try again.';end if;
 if coalesce(length(trim(p_reason)),0) not between 3 and 500 then raise exception 'Enter a correction reason (3–500 characters)';end if;
 premium:=(p_fields->>'monthly_premium')::numeric;date_value:=(p_fields->>'application_date')::date;
 if coalesce(length(trim(p_fields->>'carrier')),0) not between 1 and 100 or coalesce(length(trim(p_fields->>'policy_type')),0) not between 1 and 100 or premium is null or premium<0 or premium>100000 or date_value is null or coalesce(length(p_fields->>'policy_number'),0)>100 or coalesce(length(p_fields->>'notes'),0)>5000 then raise exception 'Carrier, policy type, valid premium and application date required';end if;
 update public.closed_business set carrier=trim(p_fields->>'carrier'),policy_type=trim(p_fields->>'policy_type'),monthly_premium=premium,application_date=date_value,policy_number=nullif(trim(p_fields->>'policy_number'),''),notes=nullif(trim(p_fields->>'notes'),'') where id=d.id returning * into changed;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'closed_deal_corrected','closed_business',d.id::text,jsonb_build_object('reason',trim(p_reason),'before',before_fields,'after',jsonb_build_object('carrier',changed.carrier,'policy_type',changed.policy_type,'monthly_premium',changed.monthly_premium,'application_date',changed.application_date,'policy_number',changed.policy_number,'notes',changed.notes)));
 return jsonb_build_object('ok',true,'id',d.id);
end;$$;
create function public.correct_closed_deal(p_deal_id uuid,p_expected jsonb,p_fields jsonb,p_reason text) returns jsonb language sql set search_path='' as $$select private.correct_closed_deal(p_deal_id,p_expected,p_fields,p_reason)$$;
revoke all on function private.correct_closed_deal(uuid,jsonb,jsonb,text),public.correct_closed_deal(uuid,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function private.correct_closed_deal(uuid,jsonb,jsonb,text),public.correct_closed_deal(uuid,jsonb,jsonb,text) to authenticated;
create policy lead_corrections_agent_read on public.lead_corrections for select to authenticated using(exists(select 1 from public.closed_business d where d.id=deal_id and d.agent_id=(select auth.uid())));
