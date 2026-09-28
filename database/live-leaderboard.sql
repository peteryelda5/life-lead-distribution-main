-- Read-only sales board. Client and policy data never enter the live channel.
create or replace function private.leaderboard_divisions() returns text[] language plpgsql stable security definer set search_path='' as $$
declare p public.profiles%rowtype;
begin
 select * into p from public.profiles where id=auth.uid() and active and not coalesce(archived,false);
 if not found then return array[]::text[]; end if;
 if p.role='admin' then return private.my_admin_divisions(); end if;
 if p.role='agent' and coalesce(auth.jwt()->>'aal','aal1')='aal2' then return array[p.division]::text[]; end if;
 return array[]::text[];
end $$;
revoke all on function private.leaderboard_divisions() from public,anon;
grant execute on function private.leaderboard_divisions() to authenticated;

create table public.leaderboard_updates(division text primary key,revision bigint not null default 0,updated_at timestamptz not null default now());
alter table public.leaderboard_updates enable row level security;
revoke all on public.leaderboard_updates from public,anon,authenticated;
grant select on public.leaderboard_updates to authenticated;
create policy leaderboard_updates_read on public.leaderboard_updates for select to authenticated using (division=any(array(select unnest(private.leaderboard_divisions()))));
insert into public.leaderboard_updates(division) values ('owner'),('vivid_life'),('legacy_life');
alter publication supabase_realtime add table public.leaderboard_updates;

create or replace function private.signal_leaderboard_update() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- Only three tiny counters; no customer or sale payload is published.
 update public.leaderboard_updates set revision=revision+1,updated_at=clock_timestamp();
 return null;
end $$;
revoke all on function private.signal_leaderboard_update() from public,anon,authenticated;
create trigger closed_business_leaderboard_signal after insert or update or delete on public.closed_business for each statement execute function private.signal_leaderboard_update();
create trigger profiles_leaderboard_signal after update on public.profiles for each statement execute function private.signal_leaderboard_update();

create or replace function private.live_leaderboard_data(p_division text default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare scopes text[]; chosen text[]; result jsonb;
 today_start timestamptz := date_trunc('day',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 week_start timestamptz := date_trunc('week',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 month_start timestamptz := date_trunc('month',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
 year_start timestamptz := date_trunc('year',now() at time zone 'America/Detroit') at time zone 'America/Detroit';
begin
 scopes:=private.leaderboard_divisions();
 if cardinality(scopes)=0 then raise exception 'Active account and required verification needed' using errcode='42501'; end if;
 if p_division is null or p_division='all' then chosen:=scopes;
 elsif p_division=any(scopes) then chosen:=array[p_division];
 else raise exception 'Division access denied' using errcode='42501'; end if;
 with sales as materialized (
 select cb.id,cb.agent_id,coalesce(p.full_name,'Former agent') agent_name,coalesce(l.division,p.division) division,cb.carrier,cb.policy_type,cb.monthly_premium,cb.annual_premium,cb.created_at
 from public.closed_business cb join public.profiles p on p.id=cb.agent_id left join public.leads l on l.id=cb.lead_id
 where coalesce(l.division,p.division)=any(chosen) and cb.created_at>=least(year_start,week_start) and cb.created_at<=now()
 ), ranked as (
 select s.agent_id,max(s.agent_name) agent_name,count(*) deals,coalesce(sum(s.annual_premium),0) ap,coalesce(sum(s.monthly_premium),0) mp
 from sales s where s.created_at>=month_start group by s.agent_id
 ), roster as (
 select r.agent_id,r.agent_name,r.deals,r.ap,r.mp from ranked r
 union all select p.id,p.full_name,0::bigint,0::numeric,0::numeric from public.profiles p where p.role='agent' and p.active and not coalesce(p.archived,false) and p.division=any(chosen) and not exists(select 1 from ranked r where r.agent_id=p.id)
 ), feed as (select id,agent_name,carrier,policy_type,monthly_premium,annual_premium,created_at from sales where created_at>=today_start order by created_at desc,id desc limit 50)
 select jsonb_build_object(
 'scopes',scopes,'division',coalesce(p_division,'all'),'timezone','America/Detroit','as_of',now(),
 'totals', (select jsonb_build_object(
 'today_ap',coalesce(sum(annual_premium) filter(where created_at>=today_start),0),'today_deals',count(*) filter(where created_at>=today_start),
 'week_ap',coalesce(sum(annual_premium) filter(where created_at>=week_start),0),'week_deals',count(*) filter(where created_at>=week_start),
 'month_ap',coalesce(sum(annual_premium) filter(where created_at>=month_start),0),'month_mp',coalesce(sum(monthly_premium) filter(where created_at>=month_start),0),'month_deals',count(*) filter(where created_at>=month_start),
 'year_ap',coalesce(sum(annual_premium) filter(where created_at>=year_start),0),'year_deals',count(*) filter(where created_at>=year_start),
 'active_producers',count(distinct agent_id) filter(where created_at>=month_start)) from sales),
 'rankings',coalesce((select jsonb_agg(to_jsonb(r) order by r.ap desc,r.deals desc,r.agent_name,r.agent_id) from roster r),'[]'::jsonb),
 'today_feed',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc,f.id desc) from feed f),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function private.live_leaderboard_data(text) from public,anon;
grant execute on function private.live_leaderboard_data(text) to authenticated;
create or replace function public.live_leaderboard(p_division text default null) returns jsonb language sql stable security invoker set search_path='' as $$select private.live_leaderboard_data(p_division)$$;
revoke all on function public.live_leaderboard(text) from public,anon;
grant execute on function public.live_leaderboard(text) to authenticated;
