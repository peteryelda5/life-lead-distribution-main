
create function private.master_dialer_session_active(p_session_id uuid) returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if current_setting('role',true)<>'service_role' or (auth.uid() is not null and auth.uid()<>'8139e230-055d-4247-8133-684ed817b4fa'::uuid) then return false;end if;
 return exists(select 1 from auth.sessions where id=p_session_id and user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid);
end $$;
revoke all on function private.master_dialer_session_active(uuid) from public,anon,authenticated;
grant usage on schema private to service_role;
grant execute on function private.master_dialer_session_active(uuid) to service_role;

create table public.master_dialer_call_grants(
 id uuid primary key,lead_id uuid references public.leads(id) on delete set null,session_id uuid not null,
 phone text not null check(phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),
 expires_at timestamptz not null default now()+interval '60 seconds',
 twilio_call_sid text unique,created_at timestamptz not null default now()
);
create index master_dialer_call_grants_lead on public.master_dialer_call_grants(lead_id);
alter table public.master_dialer_call_grants enable row level security;
revoke all on public.master_dialer_call_grants from public,anon,authenticated,service_role;
grant select,insert,update on public.master_dialer_call_grants to service_role;
create function public.master_dialer_lead_phone(p_lead_id uuid) returns text language plpgsql stable security invoker set search_path='' as $$
declare l public.leads%rowtype; raw text; digits text; i integer; hits integer=0;
begin
 select * into l from public.leads where id=p_lead_id and assigned_to='8139e230-055d-4247-8133-684ed817b4fa'::uuid and status='assigned' and coalesce(agent_status,'none')<>'dead_number';
 if not found then raise exception 'Lead is unavailable or marked dead number';end if;
 raw=nullif(trim(l.phone),'');
 if raw is null and jsonb_typeof(l.csv_headers)='array' and jsonb_typeof(l.csv_values)='array' then
 for i in 0..jsonb_array_length(l.csv_headers)-1 loop
 if lower(regexp_replace(l.csv_headers->>i,'[^a-zA-Z0-9]','','g')) in ('phone','phonenumber','mobile','mobilephone','cell','cellphone','telephone') then
 hits=hits+1;raw=l.csv_values->>i;end if;end loop;
 if hits>1 then raise exception 'Multiple phone columns; choose one phone field first';end if;
 end if;
 if raw is null or raw !~ '^[+0-9().[:space:]-]+$' then raise exception 'A valid phone field is required';end if;
 digits=regexp_replace(raw,'[^0-9]','','g');
 if length(digits)=11 and left(digits,1)='1' then digits=substring(digits,2);end if;
 if digits !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then raise exception 'A valid US-format phone number is required';end if;
 return '+1'||digits;
end $$;
revoke all on function public.master_dialer_lead_phone(uuid) from public,anon,authenticated;
grant execute on function public.master_dialer_lead_phone(uuid) to service_role;
create function public.create_master_dialer_grant(p_lead_id uuid,p_call_id uuid,p_session_id uuid) returns jsonb language plpgsql security invoker set search_path='' as $$
declare phone text;
begin
 if not exists(select 1 from public.profiles where id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and active and not coalesce(archived,false) and is_super_admin and role='admin') or not private.master_dialer_session_active(p_session_id) then raise exception 'Master session is unavailable';end if;
 phone=public.master_dialer_lead_phone(p_lead_id);
 insert into public.master_dialer_call_grants(id,lead_id,session_id,phone) values(p_call_id,p_lead_id,p_session_id,phone);
 return jsonb_build_object('to',phone,'callId',p_call_id);
end $$;
revoke all on function public.create_master_dialer_grant(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.create_master_dialer_grant(uuid,uuid,uuid) to service_role;
create function public.consume_master_dialer_grant(p_call_id uuid,p_twilio_sid text) returns text language plpgsql security invoker set search_path='' as $$
declare g public.master_dialer_call_grants%rowtype; phone text;
begin
 if p_twilio_sid is null or p_twilio_sid !~ '^CA[a-fA-F0-9]{32}$' then raise exception 'Invalid call reference';end if;
 select * into g from public.master_dialer_call_grants where id=p_call_id for update;
 if not found or g.expires_at<=now() or (g.twilio_call_sid is not null and g.twilio_call_sid<>p_twilio_sid) then raise exception 'Expired or used call authorization';end if;
 if not exists(select 1 from public.profiles where id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and active and not coalesce(archived,false) and is_super_admin and role='admin') or not private.master_dialer_session_active(g.session_id) then raise exception 'Master session is unavailable';end if;
 phone=public.master_dialer_lead_phone(g.lead_id);
 if phone<>g.phone then raise exception 'Lead phone changed; start again';end if;
 update public.master_dialer_call_grants set twilio_call_sid=p_twilio_sid where id=g.id;
 return phone;
end $$;
revoke all on function public.consume_master_dialer_grant(uuid,text) from public,anon,authenticated;
grant execute on function public.consume_master_dialer_grant(uuid,text) to service_role;
create function public.save_dialer_lead_outcome(p_lead_id uuid,p_status text,p_notes text,p_expected_status text,p_expected_notes text) returns void language plpgsql security invoker set search_path='' as $$
declare l public.leads%rowtype;
begin
 if not private.verified_portal_session() then raise exception 'Complete two-step verification';end if;
 if p_notes is null or length(p_notes)>10000 or p_status not in ('appointment_follow_up','call_back','not_interested','dead_number') then raise exception 'Invalid outcome or notes';end if;
 select * into l from public.leads where id=p_lead_id and assigned_to=auth.uid() and status='assigned' for update;
 if not found then raise exception 'Lead is no longer assigned to you';end if;
 if l.agent_status is distinct from p_expected_status or l.call_notes is distinct from p_expected_notes then raise exception 'Lead changed in another window. Reload before saving';end if;
 perform public.set_lead_call_notes(p_lead_id,p_notes);
 perform public.set_lead_agent_status(p_lead_id,p_status);
end $$;
revoke all on function public.save_dialer_lead_outcome(uuid,text,text,text,text) from public,anon;
grant execute on function public.save_dialer_lead_outcome(uuid,text,text,text,text) to authenticated;
