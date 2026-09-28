-- Division chat: immutable authors, bounded messages, retry-safe posting.
create table public.chat_messages (
 id bigint generated always as identity primary key,
 division text not null check (division in ('owner','vivid_life','legacy_life')),
 channel text not null check (channel in ('general','deals')),
 author_id uuid not null,
 author_name text not null,
 kind text not null default 'message' check (kind in ('message','deal')),
 body text not null default '' check (char_length(body)<=4000),
 deal jsonb,
 source_deal_id uuid unique,
 request_id uuid,
 created_at timestamptz not null default now(),
 unique(author_id,request_id)
);
create index chat_messages_room_id on public.chat_messages(division,channel,id desc);
create index chat_messages_author_time on public.chat_messages(author_id,created_at desc);
alter table public.chat_messages enable row level security;
revoke all on public.chat_messages from anon,authenticated;
grant select on public.chat_messages to authenticated;
create policy chat_read_scoped on public.chat_messages for select to authenticated
 using (division=any((select private.leaderboard_divisions())::text[]));
alter publication supabase_realtime add table public.chat_messages;

create function public.chat_scopes() returns text[] language sql stable security invoker set search_path='' as $$select private.leaderboard_divisions()$$;
revoke all on function public.chat_scopes() from public,anon;
grant execute on function public.chat_scopes() to authenticated;

create function private.chat_send(p_division text,p_channel text,p_body text,p_request_id uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare v_id bigint; v_name text;
begin
 if auth.uid() is null or not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Chat access denied'; end if;
 if p_channel not in ('general','deals') or p_channel is null then raise exception 'Choose a chat channel'; end if;
 if p_request_id is null or p_body is null or char_length(btrim(p_body)) not between 1 and 4000 then raise exception 'Message must contain 1–4000 characters'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,738));
 select id into v_id from public.chat_messages where author_id=auth.uid() and request_id=p_request_id;
 if found then return v_id; end if;
 if (select count(*) from public.chat_messages where author_id=auth.uid() and kind='message' and created_at>now()-interval '1 minute')>=30 then raise exception 'Please wait a moment before sending more messages'; end if;
 select full_name into v_name from public.profiles where id=auth.uid();
 insert into public.chat_messages(division,channel,author_id,author_name,body,request_id)
 values(p_division,p_channel,auth.uid(),coalesce(v_name,'Team member'),btrim(p_body),p_request_id) returning id into v_id;
 return v_id;
end $$;
revoke all on function private.chat_send(text,text,text,uuid) from public,anon;
grant execute on function private.chat_send(text,text,text,uuid) to authenticated;
create function public.chat_send(p_division text,p_channel text,p_body text,p_request_id uuid) returns bigint language sql security invoker set search_path='' as $$select private.chat_send(p_division,p_channel,p_body,p_request_id)$$;
revoke all on function public.chat_send(text,text,text,uuid) from public,anon;
grant execute on function public.chat_send(text,text,text,uuid) to authenticated;

-- Announcements have production metrics only, never client or policy identifiers.
create function private.chat_deal_announcement() returns trigger language plpgsql security definer set search_path='' as $$
declare v_div text; v_name text;
begin
 if tg_op='DELETE' then
  update public.chat_messages set deal=jsonb_build_object('withdrawn',true),body='This deal was removed from Closed Business.' where source_deal_id=old.id;
  return old;
 end if;
 select coalesce(l.division,p.division),p.full_name into v_div,v_name from public.profiles p left join public.leads l on l.id=new.lead_id where p.id=new.agent_id;
 if v_div is null then return new; end if;
 insert into public.chat_messages(division,channel,author_id,author_name,kind,source_deal_id,deal)
 values(v_div,'deals',new.agent_id,coalesce(v_name,'Team member'),'deal',new.id,
 jsonb_build_object('carrier',new.carrier,'policy_type',new.policy_type,'monthly_premium',new.monthly_premium,'annual_premium',new.annual_premium))
 on conflict(source_deal_id) do update set division=excluded.division,author_id=excluded.author_id,author_name=excluded.author_name,deal=excluded.deal,body='';
 return new;
end $$;
revoke all on function private.chat_deal_announcement() from public,anon,authenticated;
create trigger chat_deal_announcement after insert or update or delete on public.closed_business for each row execute function private.chat_deal_announcement();

-- A locked lead is the idempotency boundary: two submits cannot create two sales.
create function private.chat_close_deal(p_lead_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_policy_number text default null,p_notes text default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_lead public.leads%rowtype; v_id uuid; v_role text;
begin
 if auth.uid() is null or cardinality(private.leaderboard_divisions())=0 then raise exception 'Active account and agent verification required'; end if;
 select * into v_lead from public.leads where id=p_lead_id for update;
 if not found or not coalesce(v_lead.division=any(private.leaderboard_divisions()),false) then raise exception 'Lead is unavailable in your division'; end if;
 select role::text into v_role from public.profiles where id=auth.uid();
 if v_role='agent' and v_lead.assigned_to is distinct from auth.uid() then raise exception 'Choose a lead assigned to you'; end if;
 if v_lead.assigned_to is null or not exists(select 1 from public.profiles where id=v_lead.assigned_to and active and not coalesce(archived,false) and role='agent' and division=v_lead.division) then raise exception 'Lead must be assigned to an active agent in this division'; end if;
 if v_lead.status='closed' then
  select id into v_id from public.closed_business where lead_id=p_lead_id limit 1;
  if found then return v_id; end if;
 end if;
 if v_lead.status<>'assigned' then raise exception 'Choose an open assigned lead'; end if;
 if coalesce(btrim(p_carrier),'')='' or coalesce(btrim(p_policy_type),'')='' or char_length(p_carrier)>200 or char_length(p_policy_type)>100 then raise exception 'Carrier and policy type are required'; end if;
 if p_monthly_premium is null or p_monthly_premium<0 or p_monthly_premium>1000000 or p_monthly_premium::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a valid monthly premium'; end if;
 if p_application_date is null or p_application_date<date '2000-01-01' or p_application_date>(now() at time zone 'America/Detroit')::date then raise exception 'Enter an application date between 2000 and today'; end if;
 if char_length(p_notes)>10000 or char_length(p_policy_number)>200 then raise exception 'Policy number or notes are too long'; end if;
 insert into public.closed_business(lead_id,agent_id,carrier,policy_type,monthly_premium,application_date,policy_number,notes)
 values(p_lead_id,v_lead.assigned_to,btrim(p_carrier),btrim(p_policy_type),p_monthly_premium,p_application_date,nullif(btrim(p_policy_number),''),nullif(btrim(p_notes),'')) returning id into v_id;
 update public.leads set status='closed' where id=p_lead_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'lead_closed','lead',p_lead_id::text,jsonb_build_object('closed_business_id',v_id,'via','chat'));
 return v_id;
end $$;
revoke all on function private.chat_close_deal(uuid,text,text,numeric,date,text,text) from public,anon;
grant execute on function private.chat_close_deal(uuid,text,text,numeric,date,text,text) to authenticated;
create function public.chat_close_deal(p_lead_id uuid,p_carrier text,p_policy_type text,p_monthly_premium numeric,p_application_date date,p_policy_number text default null,p_notes text default null) returns uuid
language sql security invoker set search_path='' as $$select private.chat_close_deal(p_lead_id,p_carrier,p_policy_type,p_monthly_premium,p_application_date,p_policy_number,p_notes)$$;
revoke all on function public.chat_close_deal(uuid,text,text,numeric,date,text,text) from public,anon;
grant execute on function public.chat_close_deal(uuid,text,text,numeric,date,text,text) to authenticated;

create function private.chat_find_leads(p_division text,p_search text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_agent boolean; v_result jsonb; v_search text;
begin
 if auth.uid() is null or not coalesce(p_division=any(private.leaderboard_divisions()),false) then raise exception 'Lead access denied'; end if;
 select role='agent' into v_agent from public.profiles where id=auth.uid();
 v_search:=left(btrim(coalesce(p_search,'')),100);
 select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into v_result from (
  select l.id,l.first_name,l.last_name,l.phone,l.lead_type,l.csv_headers,l.csv_values,p.full_name as agent_name
  from public.leads l join public.profiles p on p.id=l.assigned_to
  where l.division=p_division and l.status='assigned' and (not v_agent or l.assigned_to=auth.uid())
  and p.active and not coalesce(p.archived,false) and p.role='agent' and p.division=l.division
  and (v_search='' or l.id::text=v_search or concat_ws(' ',l.first_name,l.last_name,l.phone,l.csv_values::text) ilike '%'||replace(replace(replace(v_search,'\','\\'),'%','\%'),'_','\_')||'%')
  order by l.created_at desc limit 30
 ) r;
 return v_result;
end $$;
revoke all on function private.chat_find_leads(text,text) from public,anon;
grant execute on function private.chat_find_leads(text,text) to authenticated;
create function public.chat_find_leads(p_division text,p_search text default '') returns jsonb language sql stable security invoker set search_path='' as $$select private.chat_find_leads(p_division,p_search)$$;
revoke all on function public.chat_find_leads(text,text) from public,anon;
grant execute on function public.chat_find_leads(text,text) to authenticated;
