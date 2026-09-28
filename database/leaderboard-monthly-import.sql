-- Imported monthly AP is an adjustment to recorded production, not synthetic sales.
create table private.leaderboard_monthly_import (
 month date not null,
 division text not null check(division in ('owner','vivid_life','legacy_life')),
 entry_key text not null,
 agent_id uuid references public.profiles(id),
 display_name text not null,
 snapshot_ap numeric not null,
 ap_adjustment numeric not null,
 captured_at timestamptz not null default now(),
 primary key(month,division,entry_key)
);
alter table private.leaderboard_monthly_import enable row level security;
revoke all on private.leaderboard_monthly_import from public,anon,authenticated;
alter function private.live_leaderboard_data(text) rename to recorded_leaderboard_data;
create function private.live_leaderboard_data(p_division text default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;chosen text[];m date:=(date_trunc('month',now() at time zone 'America/Detroit'))::date;adjustment numeric;year_adjustment numeric;ranking jsonb;has_month boolean;has_year boolean;
begin
 result:=private.recorded_leaderboard_data(p_division);
 chosen:=case when p_division is null or p_division='all' then private.leaderboard_divisions() else array[p_division] end;
 select coalesce(sum(ap_adjustment),0),count(*)>0 into adjustment,has_month from private.leaderboard_monthly_import where month=m and division=any(chosen);
 select coalesce(sum(ap_adjustment),0),count(*)>0 into year_adjustment,has_year from private.leaderboard_monthly_import where month>=date_trunc('year',m)::date and month<=m and division=any(chosen);
 if has_year then
  result:=jsonb_set(result,'{totals,year_ap}',to_jsonb((result->'totals'->>'year_ap')::numeric+year_adjustment));
  result:=jsonb_set(result,'{totals,year_deals}','null'::jsonb);
 end if;
 if not has_month then return result;end if;
 with actual as (select r->>'agent_id' as entry_key,r from jsonb_array_elements(result->'rankings') r), imported as (
 select entry_key,max(display_name) display_name,sum(ap_adjustment) adjustment from private.leaderboard_monthly_import where month=m and division=any(chosen) group by entry_key
 ), merged as (
 select coalesce(a.entry_key,i.entry_key) agent_id,coalesce(a.r->>'agent_name',i.display_name) agent_name,
 coalesce((a.r->>'ap')::numeric,0)+coalesce(i.adjustment,0) ap,
 case when i.entry_key is null then (a.r->>'deals')::bigint end deals,
 case when i.entry_key is null then (a.r->>'mp')::numeric end mp,
 i.entry_key is not null imported
 from actual a full join imported i using(entry_key)
 ) select coalesce(jsonb_agg(to_jsonb(x) order by ap desc,agent_name),'[]'::jsonb) into ranking from merged x;
 result:=jsonb_set(result,'{rankings}',ranking);
 result:=jsonb_set(result,'{totals,month_ap}',to_jsonb((result->'totals'->>'month_ap')::numeric+adjustment));
 result:=jsonb_set(result,'{totals,month_deals}','null'::jsonb);
 result:=jsonb_set(result,'{totals,month_mp}','null'::jsonb);
 result:=jsonb_set(result,'{totals,active_producers}',to_jsonb((select count(*) from jsonb_array_elements(ranking) r where (r->>'ap')::numeric>0)));
 result:=result||jsonb_build_object('imported_month',m,'import_note','September includes imported AP totals. Historical deal counts and monthly premiums were not supplied. New recorded deals add automatically.');
 if m=date '2026-09-01' and array['owner','vivid_life']::text[]<@chosen then result:=result||jsonb_build_object('month_goal',100000);end if;
 return result;
end $$;
revoke all on function private.live_leaderboard_data(text) from public,anon;
grant execute on function private.live_leaderboard_data(text) to authenticated;
-- Refresh the wrapper after renaming, so it resolves to the augmented implementation.
create or replace function public.live_leaderboard(p_division text default null) returns jsonb language sql stable security invoker set search_path='' as $$select private.live_leaderboard_data(p_division)$$;
