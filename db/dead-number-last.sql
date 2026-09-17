-- Database ordering keeps dead numbers last across the complete paginated list.
set local lock_timeout='3s';
alter table public.leads add column is_dead_number boolean generated always as (coalesce(agent_status='dead_number',false)) stored;
create index leads_agent_dead_last_idx on public.leads(assigned_to,is_dead_number,assigned_at desc,id desc) where status='assigned';
