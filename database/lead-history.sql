create table public.lead_history_events (
 id bigint generated always as identity primary key,
 lead_id uuid not null,
 division text not null references public.divisions(id),
 actor_id uuid,
 action text not null,
 assigned_from uuid,
 assigned_to uuid,
 source_division text,
 changed_fields text[] not null default '{}',
 lead_type text,
 created_at timestamptz not null default now()
);
create index lead_history_division_cursor on public.lead_history_events(division,id desc);
create index lead_history_lead_cursor on public.lead_history_events(lead_id,id desc);
alter table public.lead_history_events enable row level security;
revoke all on public.lead_history_events from public,anon,authenticated;
grant select on public.lead_history_events to authenticated;
create policy history_admin_read on public.lead_history_events for select to authenticated using (division=any(private.my_admin_divisions()));
create function private.capture_lead_history() returns trigger language plpgsql security definer set search_path='' as $$
declare before_row jsonb; after_row jsonb; fields text[]; event_action text;
begin
 if tg_op='DELETE' then
  insert into public.lead_history_events(lead_id,division,actor_id,action,assigned_from,lead_type) values(old.id,old.division,auth.uid(),'deleted',old.assigned_to,old.lead_type);return old;
 end if;
 if tg_op='INSERT' then
  insert into public.lead_history_events(lead_id,division,actor_id,action,assigned_to,lead_type) values(new.id,new.division,coalesce(auth.uid(),new.uploaded_by),'uploaded',new.assigned_to,new.lead_type);return new;
 end if;
 before_row:=to_jsonb(old);after_row:=to_jsonb(new);
 select coalesce(array_agg(k order by k),'{}') into fields from jsonb_object_keys(after_row) k where k not in ('updated_at','is_dead_number') and before_row->k is distinct from after_row->k;
 if cardinality(fields)=0 then return new;end if;
 event_action:=case when new.division is distinct from old.division then 'division_transfer' when new.status='closed' and old.status<>'closed' then 'closed' when old.status='closed' and new.status<>'closed' then 'reopened' when new.assigned_to is distinct from old.assigned_to then case when new.assigned_to is null then 'reclaimed' when old.assigned_to is null then 'assigned' else 'reassigned' end else 'changed' end;
 insert into public.lead_history_events(lead_id,division,actor_id,action,assigned_from,assigned_to,source_division,changed_fields,lead_type) values(new.id,new.division,auth.uid(),event_action,old.assigned_to,new.assigned_to,case when new.division is distinct from old.division then old.division end,fields,new.lead_type);
 return new;
end $$;
revoke all on function private.capture_lead_history() from public,anon,authenticated;
create trigger z_lead_history after insert or update or delete on public.leads for each row execute function private.capture_lead_history();
-- Snapshot is explicitly not a reconstruction of past assignment events.
insert into public.lead_history_events(lead_id,division,actor_id,action,assigned_to,lead_type)
select id,division,uploaded_by,'baseline',assigned_to,lead_type from public.leads;
create function private.lead_history_page(p_division text,p_lead_id uuid default null,p_before bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not coalesce(p_division=any(private.my_admin_divisions()),false) then raise exception 'You cannot view that division history' using errcode='42501';end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.id desc),'[]') into result from (
 select e.*,nullif(concat_ws(' ',l.first_name,l.last_name),'') lead_name,
 a.full_name actor_name,af.full_name previous_agent,atp.full_name recipient_name
 from (select * from public.lead_history_events where division=p_division and (p_lead_id is null or lead_id=p_lead_id) and (p_before is null or id<p_before) order by id desc limit 51) e
 left join public.leads l on l.id=e.lead_id and l.division=p_division
 left join public.profiles a on a.id=e.actor_id
 left join public.profiles af on af.id=e.assigned_from
 left join public.profiles atp on atp.id=e.assigned_to
 )r;
 return result;
end $$;
create function public.lead_history_page(p_division text,p_lead_id uuid default null,p_before bigint default null)
returns jsonb language sql security invoker set search_path='' as $$select private.lead_history_page(p_division,p_lead_id,p_before)$$;
revoke all on function private.lead_history_page(text,uuid,bigint),public.lead_history_page(text,uuid,bigint) from public,anon;
grant execute on function private.lead_history_page(text,uuid,bigint),public.lead_history_page(text,uuid,bigint) to authenticated;
