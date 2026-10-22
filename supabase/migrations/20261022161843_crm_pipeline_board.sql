-- Pipeline-specific read API: exact carrier filtering and local-day follow-ups.
-- Retain the existing PIN, MFA, agency and archived-agency access checks.
create function private.book_crm_pipeline(
 p_search text default '',p_agent uuid default null,p_carrier text default '',
 p_stage text default '',p_page int default 1,p_limit int default 50,p_view text default 'board',
 p_today_start timestamptz default null,p_today_end timestamptz default null
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; lim int:=greatest(1,least(coalesce(p_limit,50),2000)); offn int;
 day_start timestamptz:=coalesce(p_today_start,date_trunc('day',now()));
 day_end timestamptz:=coalesce(p_today_end,date_trunc('day',now())+interval '1 day');
begin
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_view is null or p_view<>all(array['board','list']) then raise exception 'Invalid pipeline view';end if;
 if coalesce(p_stage,'')<>'' and p_stage<>all(array['new','contacted','submitted','approved','in_force','lapsed','cancelled']) then raise exception 'Invalid pipeline stage';end if;
 if day_end<=day_start or day_end-day_start>interval '48 hours' then raise exception 'Invalid follow-up day';end if;
 offn:=(greatest(1,least(coalesce(p_page,1),100000))-1)*lim;
 with permitted as materialized (
  select r.* from private.book_crm_records r where private.book_crm_can_access(r.agent_id,r.deal_id) and (p_agent is null or r.agent_id=p_agent)
 ), matched as materialized (
  select * from permitted r where (coalesce(p_carrier,'')='' or r.carrier=p_carrier)
  and (coalesce(p_search,'')='' or concat_ws(' ',r.client_name,r.agent_name,r.carrier,r.policy_type,r.policy_number,r.phone,r.email,r.address_line1,r.city,r.state,r.zip) ilike '%'||left(p_search,100)||'%')
 ), filtered as materialized (select * from matched where coalesce(p_stage,'')='' or pipeline_stage=p_stage),
 paged as (select * from filtered order by created_at desc,id limit lim offset offn),
 ranked as (select f.*,row_number() over(partition by pipeline_stage order by created_at desc,id) rn from filtered f),
 today as materialized (
  select t.*,f.client_name,f.agent_name from private.book_crm_tasks t join filtered f on f.id=t.client_id
  where t.completed_at is null and t.due_at>=day_start and t.due_at<day_end
 ), todaypage as (select * from today order by due_at,id limit 8)
 select jsonb_build_object(
  'rows',case when p_view='list' then coalesce((select jsonb_agg(to_jsonb(paged) order by created_at desc,id) from paged),'[]') else '[]'::jsonb end,
  'pipeline',case when p_view='board' then coalesce((select jsonb_agg(to_jsonb(ranked)-'rn' order by created_at desc,id) from ranked where rn<=25),'[]') else '[]'::jsonb end,
  'count',(select count(*) from filtered),
  'stage_counts',coalesce((select jsonb_object_agg(pipeline_stage,n) from (select pipeline_stage,count(*) n from matched group by pipeline_stage)s),'{}'),
  'carriers',coalesce((select jsonb_agg(carrier order by carrier) from (select distinct carrier from permitted where coalesce(carrier,'')<>'')c),'[]'),
  'today_tasks',coalesce((select jsonb_agg(to_jsonb(todaypage) order by due_at,id) from todaypage),'[]'),
  'today_task_count',(select count(*) from today)
 ) into result;
 return result;
end;$$;

create function public.book_crm_pipeline(
 p_search text default '',p_agent uuid default null,p_carrier text default '',
 p_stage text default '',p_page int default 1,p_limit int default 50,p_view text default 'board',
 p_today_start timestamptz default null,p_today_end timestamptz default null
) returns jsonb language sql security invoker set search_path='' as $$
 select private.book_crm_pipeline(p_search,p_agent,p_carrier,p_stage,p_page,p_limit,p_view,p_today_start,p_today_end)
$$;
revoke all on function private.book_crm_pipeline(text,uuid,text,text,int,int,text,timestamptz,timestamptz),public.book_crm_pipeline(text,uuid,text,text,int,int,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function private.book_crm_pipeline(text,uuid,text,text,int,int,text,timestamptz,timestamptz),public.book_crm_pipeline(text,uuid,text,text,int,int,text,timestamptz,timestamptz) to authenticated;
notify pgrst,'reload schema';
