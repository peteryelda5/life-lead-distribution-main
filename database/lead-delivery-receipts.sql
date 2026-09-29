create table public.lead_delivery_receipts(
 id bigint generated always as identity primary key,
 transaction_id bigint not null default txid_current(),
 delivered_at timestamptz not null default now(),
 sender_id uuid, sender_name text,
 source_division text not null, source_name text,
 destination_division text not null, destination_name text,
 recipient_id uuid, recipient_name text,
 lead_count integer not null check(lead_count>0),
 lead_ids uuid[] not null,
 historical boolean not null default false
);
create index delivery_receipts_division_cursor on public.lead_delivery_receipts(destination_division,id desc);
create index delivery_receipts_transaction on public.lead_delivery_receipts(transaction_id);
create index delivery_receipts_leads on public.lead_delivery_receipts using gin(lead_ids);
alter table public.lead_delivery_receipts enable row level security;
revoke all on public.lead_delivery_receipts from public,anon,authenticated;
grant select on public.lead_delivery_receipts to authenticated;
create policy delivery_receipts_admin_read on public.lead_delivery_receipts for select to authenticated using(destination_division=any(private.my_admin_divisions()));
create function private.capture_delivery_receipts() returns trigger language plpgsql security definer set search_path='' as $$
declare r record; prior_id bigint; sender text; destination text; recipient text; source text;
begin
 select full_name into sender from public.profiles where id=auth.uid();
 for r in select o.division source_division,n.division destination_division,n.assigned_to recipient_id,array_agg(n.id order by n.id) ids
 from new_delivery_rows n join old_delivery_rows o on o.id=n.id
 where n.status in ('assigned','unassigned') and (n.division is distinct from o.division or (n.assigned_to is not null and n.assigned_to is distinct from o.assigned_to))
 group by o.division,n.division,n.assigned_to
 loop
 select name into destination from public.divisions where id=r.destination_division;
 select name into source from public.divisions where id=r.source_division;
 select full_name into recipient from public.profiles where id=r.recipient_id;
 -- The atomic division + agent RPC performs two updates in one transaction.
 -- Combine only the exact same lead set from its immediately preceding pool delivery.
 select id into prior_id from public.lead_delivery_receipts
 where transaction_id=txid_current() and not historical and sender_id is not distinct from auth.uid()
 and destination_division=r.source_division and recipient_id is null and lead_ids=r.ids
 order by id desc limit 1;
 if prior_id is not null then
 update public.lead_delivery_receipts set destination_division=r.destination_division,destination_name=destination,recipient_id=r.recipient_id,recipient_name=recipient where id=prior_id;
 else
 insert into public.lead_delivery_receipts(sender_id,sender_name,source_division,source_name,destination_division,destination_name,recipient_id,recipient_name,lead_count,lead_ids)
 values(auth.uid(),sender,r.source_division,source,r.destination_division,destination,r.recipient_id,recipient,cardinality(r.ids),r.ids);
 end if;
 end loop;
 return null;
end $$;
revoke all on function private.capture_delivery_receipts() from public,anon,authenticated;
create trigger z_delivery_receipts after update on public.leads referencing old table as old_delivery_rows new table as new_delivery_rows for each statement execute function private.capture_delivery_receipts();
-- Reconstruct only deliveries recorded by existing history; never treat baseline snapshots as deliveries.
with per_lead as (
 select lead_id,created_at,actor_id,
 (array_agg(coalesce(source_division,division) order by id))[1] source_division,
 (array_agg(division order by id desc))[1] destination_division,
 (array_agg(assigned_to order by id desc))[1] recipient_id
 from public.lead_history_events e where action in ('assigned','reassigned') or (action='division_transfer' and exists(select 1 from public.audit_logs a where a.action='leads_sent_to_division' and a.created_at=e.created_at and a.actor_id is not distinct from e.actor_id and a.details->'lead_ids' @> to_jsonb(array[e.lead_id]))) group by lead_id,created_at,actor_id
), batches as (
 select created_at,actor_id,source_division,destination_division,recipient_id,array_agg(lead_id order by lead_id) ids from per_lead
 group by created_at,actor_id,source_division,destination_division,recipient_id
)
insert into public.lead_delivery_receipts(transaction_id,delivered_at,sender_id,sender_name,source_division,source_name,destination_division,destination_name,recipient_id,recipient_name,lead_count,lead_ids,historical)
select 0,b.created_at,b.actor_id,s.full_name,b.source_division,sd.name,b.destination_division,dd.name,b.recipient_id,r.full_name,cardinality(b.ids),b.ids,true
from batches b left join public.profiles s on s.id=b.actor_id left join public.profiles r on r.id=b.recipient_id
left join public.divisions sd on sd.id=b.source_division left join public.divisions dd on dd.id=b.destination_division
order by b.created_at,b.source_division,b.destination_division,b.recipient_id;
create function private.delivery_receipts_page(p_division text,p_before bigint default null,p_lead_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare scopes text[];
begin
 scopes:=private.my_admin_divisions();
 if cardinality(scopes)=0 or (p_division is distinct from 'all' and not coalesce(p_division=any(scopes),false)) then raise exception 'Division access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') from (
 select id,delivered_at,sender_name,source_name,destination_name,recipient_name,recipient_id,lead_count,historical
 from public.lead_delivery_receipts where destination_division=any(scopes) and (p_division='all' or destination_division=p_division)
 and (p_before is null or id<p_before) and (p_lead_id is null or lead_ids @> array[p_lead_id]) order by id desc limit 51
 )x);
end $$;
create function public.delivery_receipts_page(p_division text,p_before bigint default null,p_lead_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$select private.delivery_receipts_page(p_division,p_before,p_lead_id)$$;
revoke all on function private.delivery_receipts_page(text,bigint,uuid),public.delivery_receipts_page(text,bigint,uuid) from public,anon;
grant execute on function private.delivery_receipts_page(text,bigint,uuid),public.delivery_receipts_page(text,bigint,uuid) to authenticated;
