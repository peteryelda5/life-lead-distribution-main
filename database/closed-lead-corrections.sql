create table public.lead_corrections (
 id bigint generated always as identity primary key,
 lead_id uuid not null,
 deal_id uuid,
 division text not null,
 actor_id uuid,
 reason text not null,
 before_data jsonb not null,
 after_data jsonb not null,
 created_at timestamptz not null default now()
);
create index lead_corrections_by_lead on public.lead_corrections(lead_id,id desc);
alter table public.lead_corrections enable row level security;
revoke all on public.lead_corrections from public,anon,authenticated;
grant select on public.lead_corrections to authenticated;
create policy lead_corrections_admin_read on public.lead_corrections for select to authenticated
using (division=any(private.my_admin_divisions()));
create policy "portal verified session required" on public.lead_corrections as restrictive for all to authenticated
using ((select private.verified_portal_session())) with check ((select private.verified_portal_session()));

-- The trigger preserves a snapshot even if an admin updates a closed lead
-- through a different client. Ordinary status and call-note edits are excluded.
create or replace function private.capture_closed_lead_correction() returns trigger
language plpgsql security definer set search_path='' as $$
declare d_id uuid; reason_text text;
begin
 if old.status <> 'closed' or new.status <> 'closed' or
 (old.first_name,old.last_name,old.phone,old.email,old.state,old.source,old.notes,
  old.lead_type,old.csv_values) is not distinct from
 (new.first_name,new.last_name,new.phone,new.email,new.state,new.source,new.notes,
  new.lead_type,new.csv_values) then return new; end if;
 select id into d_id from public.closed_business where lead_id=old.id order by created_at desc limit 1;
 if d_id is null then return new; end if;
 reason_text:=coalesce(nullif(btrim(current_setting('lld.correction_reason',true)),''),'Lead details corrected');
 insert into public.lead_corrections(lead_id,deal_id,division,actor_id,reason,before_data,after_data)
 values(old.id,d_id,new.division,auth.uid(),reason_text,to_jsonb(old),to_jsonb(new));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'closed_lead_corrected','lead',old.id::text,
 jsonb_build_object('deal_id',d_id,'division',new.division,'correction_reason',reason_text));
 return new;
end $$;
revoke all on function private.capture_closed_lead_correction() from public,anon,authenticated;
create trigger z_closed_lead_correction after update on public.leads for each row
execute function private.capture_closed_lead_correction();

create or replace function public.correct_closed_lead(
 p_deal_id uuid,p_expected_updated_at timestamptz,p_fields jsonb,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.closed_business%rowtype; l public.leads%rowtype; changed public.leads%rowtype;
 new_first text; new_last text; new_csv jsonb;
begin
 if auth.jwt()->>'aal' <> 'aal2' then raise exception 'Two-step verification required' using errcode='42501';end if;
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
 if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin'
 and p.active and not coalesce(p.archived,false)) or
 not coalesce(l.division=any(private.my_admin_divisions()),false) then
  raise exception 'You cannot correct this division’s closed leads' using errcode='42501';
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
end $$;
revoke all on function public.correct_closed_lead(uuid,timestamptz,jsonb,text) from public,anon;
grant execute on function public.correct_closed_lead(uuid,timestamptz,jsonb,text) to authenticated;
