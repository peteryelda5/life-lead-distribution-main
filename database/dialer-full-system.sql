create table public.dialer_accounts (
 user_id uuid not null references public.profiles(id), livemode boolean not null,
 customer_id text not null unique check(customer_id ~ '^cus_[A-Za-z0-9]+$'), subscription_id text unique,
 subscription_status text not null default 'none', paid_invoice boolean not null default false,
 period_start timestamptz,period_end timestamptz,verified_at timestamptz,
 cancel_at_period_end boolean not null default false, overage_limit_cents integer not null default 5000 check(overage_limit_cents between 0 and 50000),
 checkout_request uuid,checkout_session_id text,checkout_expires timestamptz,portal_config_id text,
 primary key(user_id,livemode),check(period_end is null or period_end>period_start)
);
create table public.dialer_periods (
 user_id uuid not null,livemode boolean not null,starts_at timestamptz not null,ends_at timestamptz not null,
 subscription_id text not null,customer_id text not null,
 primary key(user_id,livemode,starts_at),foreign key(user_id,livemode) references public.dialer_accounts(user_id,livemode),check(ends_at>starts_at)
);
create table public.dialer_numbers (
 user_id uuid not null,livemode boolean not null,slot integer not null check(slot between 1 and 3),
 phone text not null check(phone ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'),state text not null default 'selected' check(state in ('selected','provisioning','active','releasing','released')),
 purchase_key uuid not null default gen_random_uuid(),purchase_started boolean not null default false,twilio_sid text unique,
 updated_at timestamptz not null default now(),
 primary key(user_id,livemode,slot),foreign key(user_id,livemode) references public.dialer_accounts(user_id,livemode),unique(purchase_key),
 check(twilio_sid is null or twilio_sid ~ '^PN[0-9a-fA-F]{32}$')
);
create unique index dialer_numbers_exclusive_phone on public.dialer_numbers(phone) where state in ('provisioning','active','releasing');
create table public.dialer_calls (
 id uuid primary key,user_id uuid not null,livemode boolean not null,period_start timestamptz not null,
 lead_id uuid references public.leads(id) on delete set null,session_id uuid not null,phone text not null,caller_id text not null,
 created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '60 seconds',
 max_seconds integer not null check(max_seconds between 60 and 1800),parent_sid text unique,child_sid text unique,
 finished boolean not null default false,duration_seconds integer not null default 0 check(duration_seconds between 0 and 7200),
 used_minutes integer generated always as ((duration_seconds+59)/60) stored,call_status text,finished_at timestamptz,
 foreign key(user_id,livemode,period_start) references public.dialer_periods(user_id,livemode,starts_at)
);
create index dialer_calls_user_period on public.dialer_calls(user_id,livemode,period_start);
create table public.dialer_overage_invoices (
 invoice_id text primary key,user_id uuid not null,livemode boolean not null,period_start timestamptz not null,
 amount_cents integer not null check(amount_cents>=0),used_minutes integer not null,invoice_item_id text,state text not null default 'pending',
 unique(user_id,livemode,period_start),foreign key(user_id,livemode,period_start) references public.dialer_periods(user_id,livemode,starts_at)
);
alter table public.dialer_accounts enable row level security;
alter table public.dialer_periods enable row level security;
alter table public.dialer_numbers enable row level security;
alter table public.dialer_calls enable row level security;
alter table public.dialer_overage_invoices enable row level security;
revoke all on public.dialer_accounts,public.dialer_periods,public.dialer_numbers,public.dialer_calls,public.dialer_overage_invoices from public,anon,authenticated;
grant select,insert,update on public.dialer_accounts,public.dialer_periods,public.dialer_numbers,public.dialer_calls,public.dialer_overage_invoices to service_role;
create function private.dialer_session_active(p_user uuid,p_session uuid) returns boolean language sql security definer set search_path='' as $$
 select current_setting('role',true)='service_role' and (auth.uid() is null or auth.uid()=p_user) and exists(select 1 from auth.sessions s join public.profiles p on p.id=s.user_id where s.id=p_session and p.id=p_user and p.active and not p.archived and p.role in ('agent','admin'));
$$;
revoke all on function private.dialer_session_active(uuid,uuid) from public,anon,authenticated;
grant execute on function private.dialer_session_active(uuid,uuid) to service_role;
create function public.dialer_entitled(p_user uuid,p_live boolean) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.dialer_accounts a join public.profiles p on p.id=a.user_id where a.user_id=p_user and a.livemode=p_live and p.active and not p.archived and a.subscription_status='active' and a.paid_invoice and a.period_start<=now() and a.period_end>now() and a.verified_at>now()-interval '5 minutes');
$$;
create function public.dialer_get_account(p_user uuid,p_live boolean) returns jsonb language sql security invoker set search_path='' as $$
 select coalesce((select to_jsonb(a) from public.dialer_accounts a where user_id=p_user and livemode=p_live),'{}'::jsonb);
$$;
create function public.dialer_set_customer(p_user uuid,p_live boolean,p_customer text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;begin
 if not exists(select 1 from public.profiles where id=p_user and active and not archived and role in ('agent','admin')) then raise exception 'Account unavailable';end if;
 insert into public.dialer_accounts(user_id,livemode,customer_id) values(p_user,p_live,p_customer) on conflict(user_id,livemode) do nothing;
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live;
 return to_jsonb(a);
end $$;
create function public.dialer_sync_subscription(p_user uuid,p_live boolean,p_snapshot jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;start_at timestamptz;end_at timestamptz;begin
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found or a.customer_id is distinct from p_snapshot->>'customer_id' then raise exception 'Billing account mismatch';end if;
 start_at:=nullif(p_snapshot->>'period_start','')::timestamptz;end_at:=nullif(p_snapshot->>'period_end','')::timestamptz;
 update public.dialer_accounts set subscription_id=p_snapshot->>'subscription_id',subscription_status=p_snapshot->>'status',paid_invoice=coalesce((p_snapshot->>'paid')::boolean,false),period_start=start_at,period_end=end_at,verified_at=now(),cancel_at_period_end=coalesce((p_snapshot->>'cancel_at_period_end')::boolean,false) where user_id=p_user and livemode=p_live returning * into a;
 if start_at is not null and end_at is not null then
 insert into public.dialer_periods(user_id,livemode,starts_at,ends_at,subscription_id,customer_id) values(p_user,p_live,start_at,end_at,a.subscription_id,a.customer_id) on conflict(user_id,livemode,starts_at) do update set ends_at=excluded.ends_at;
 end if;return to_jsonb(a);
end $$;
create function public.dialer_claim_checkout(p_user uuid,p_live boolean) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;begin
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found then raise exception 'Billing account missing';end if;
 if a.subscription_status in ('active','past_due','unpaid','incomplete','trialing','paused') then raise exception 'Manage your existing subscription instead';end if;
 if a.checkout_expires is null or a.checkout_expires<=now() then update public.dialer_accounts set checkout_request=gen_random_uuid(),checkout_session_id=null,checkout_expires=now()+interval '1 hour' where user_id=p_user and livemode=p_live returning * into a;end if;
 return to_jsonb(a);
end $$;
create function public.dialer_set_checkout(p_user uuid,p_live boolean,p_request uuid,p_session text) returns void language plpgsql security invoker set search_path='' as $$
begin update public.dialer_accounts set checkout_session_id=p_session where user_id=p_user and livemode=p_live and checkout_request=p_request;if not found then raise exception 'Checkout changed';end if;end $$;
create function public.dialer_set_limit(p_user uuid,p_live boolean,p_limit integer) returns void language plpgsql security invoker set search_path='' as $$
begin if p_limit not in (0,2500,5000,10000) then raise exception 'Choose an allowed extra-minute limit';end if;update public.dialer_accounts set overage_limit_cents=p_limit where user_id=p_user and livemode=p_live;end $$;
create function public.dialer_summary(p_user uuid,p_live boolean) returns jsonb language sql security invoker set search_path='' as $$
 with a as(select * from public.dialer_accounts where user_id=p_user and livemode=p_live), t as(select coalesce(sum(c.used_minutes),0) as minutes,count(c.id) filter(where c.finished) as calls,count(c.id) filter(where not c.finished and c.parent_sid is not null) as pending from a left join public.dialer_calls c on c.user_id=a.user_id and c.livemode=a.livemode and c.period_start=a.period_start)
 select coalesce((select jsonb_build_object('subscriptionStatus',a.subscription_status,'paid',a.paid_invoice,'entitled',public.dialer_entitled(p_user,p_live),'periodStart',a.period_start,'periodEnd',a.period_end,'cancelAtPeriodEnd',a.cancel_at_period_end,'usedMinutes',t.minutes,'calls',t.calls,'pendingCalls',t.pending,'includedMinutes',5000,'remainingMinutes',greatest(5000-t.minutes,0),'estimatedOverageCents',greatest(t.minutes-5000,0)*3,'overageLimitCents',a.overage_limit_cents,'alertPercent',case when t.minutes>=4750 then 95 when t.minutes>=4000 then 80 else null end,'numbers',coalesce((select jsonb_agg(jsonb_build_object('slot',slot,'phoneNumber',phone,'state',state) order by slot) from public.dialer_numbers where user_id=p_user and livemode=p_live),'[]'::jsonb)) from a cross join t),'{}'::jsonb);
$$;
create function public.dialer_select_number(p_user uuid,p_live boolean,p_slot integer,p_phone text) returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.dialer_numbers(user_id,livemode,slot,phone) values(p_user,p_live,p_slot,p_phone) on conflict(user_id,livemode,slot) do update set phone=excluded.phone,state='selected',purchase_key=gen_random_uuid(),purchase_started=false,twilio_sid=null,updated_at=now() where public.dialer_numbers.state in ('selected','released');
 if not found then raise exception 'This slot already has an activated or pending number';end if;
end $$;
create function public.dialer_begin_number(p_user uuid,p_session uuid,p_live boolean,p_slot integer,p_phone text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare n public.dialer_numbers%rowtype;begin
 if not private.dialer_session_active(p_user,p_session) or not public.dialer_entitled(p_user,p_live) or (not p_live and p_user<>'8139e230-055d-4247-8133-684ed817b4fa'::uuid) then raise exception 'An active live subscription is required to purchase agent numbers';end if;
 select * into n from public.dialer_numbers where user_id=p_user and livemode=p_live and slot=p_slot for update;
 if not found or n.phone is distinct from p_phone or n.state in ('releasing','released') then raise exception 'Select and confirm your number first';end if;
 update public.dialer_numbers set state=case when state='selected' then 'provisioning' else state end where user_id=p_user and livemode=p_live and slot=p_slot returning * into n;
 return to_jsonb(n);
end $$;
create function public.dialer_claim_number_purchase(p_key uuid) returns boolean language plpgsql security invoker set search_path='' as $$
declare affected integer;begin update public.dialer_numbers set purchase_started=true where purchase_key=p_key and state='provisioning' and not purchase_started;get diagnostics affected=row_count;return affected=1;end $$;
create function public.dialer_finish_number(p_key uuid,p_phone text,p_sid text) returns void language plpgsql security invoker set search_path='' as $$
begin if p_sid is null or p_sid !~ '^PN[0-9a-fA-F]{32}$' then raise exception 'Invalid provider number';end if;update public.dialer_numbers set state='active',twilio_sid=p_sid,updated_at=now() where purchase_key=p_key and phone=p_phone and state in ('provisioning','active') and (twilio_sid is null or twilio_sid=p_sid);if not found then raise exception 'Number activation mismatch';end if;end $$;
create function public.dialer_lead_phone(p_user uuid,p_lead uuid) returns text language plpgsql stable security invoker set search_path='' as $$
declare l public.leads%rowtype;raw text;digits text;i integer;hits integer=0;begin
 select * into l from public.leads where id=p_lead and assigned_to=p_user and status='assigned' and coalesce(agent_status,'none')<>'dead_number';if not found then raise exception 'Lead is unavailable or marked Dead Number';end if;
 raw:=nullif(trim(l.phone),'');if raw is null and jsonb_typeof(l.csv_headers)='array' and jsonb_typeof(l.csv_values)='array' then for i in 0..jsonb_array_length(l.csv_headers)-1 loop if lower(regexp_replace(l.csv_headers->>i,'[^a-zA-Z0-9]','','g')) in ('phone','phonenumber','mobile','mobilephone','cell','cellphone','telephone') then hits:=hits+1;raw:=l.csv_values->>i;end if;end loop;if hits>1 then raise exception 'Multiple phone columns; choose one first';end if;end if;
 if raw is null or raw !~ '^[+0-9().[:space:]-]+$' then raise exception 'A valid phone field is required';end if;digits:=regexp_replace(raw,'[^0-9]','','g');if length(digits)=11 and left(digits,1)='1' then digits:=substring(digits,2);end if;if digits !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then raise exception 'A valid US phone number is required';end if;return '+1'||digits;
end $$;
create function public.dialer_create_call(p_user uuid,p_session uuid,p_live boolean,p_lead uuid,p_call uuid,p_slot integer) returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.dialer_accounts%rowtype;number text;destination text;used integer;reserve integer;remaining integer;limit_seconds integer;begin
 select * into a from public.dialer_accounts where user_id=p_user and livemode=p_live for update;
 if not found or not private.dialer_session_active(p_user,p_session) or not public.dialer_entitled(p_user,p_live) or (not p_live and p_user<>'8139e230-055d-4247-8133-684ed817b4fa'::uuid) then raise exception 'An active live subscription is required for agent calling';end if;
 if exists(select 1 from public.dialer_calls where user_id=p_user and livemode=p_live and not finished and ((parent_sid is null and expires_at>now()) or (parent_sid is not null and created_at>now()-interval '40 minutes'))) then raise exception 'Finish the current call or refresh its usage before dialing again';end if;
 select phone into number from public.dialer_numbers where user_id=p_user and livemode=p_live and slot=p_slot and state='active';if number is null then raise exception 'Activate your selected caller ID first';end if;
 destination:=public.dialer_lead_phone(p_user,p_lead);if destination=number then raise exception 'You cannot call your caller ID';end if;
 select coalesce(sum(used_minutes),0),coalesce(sum(case when not finished and parent_sid is not null then (max_seconds+59)/60 else 0 end),0) into used,reserve from public.dialer_calls where user_id=p_user and livemode=p_live and period_start=a.period_start;
 remaining:=5000+a.overage_limit_cents/3-used-reserve;if remaining<=0 then raise exception 'Your extra-minute spending limit has been reached';end if;limit_seconds:=least(1800,remaining*60);
 insert into public.dialer_calls(id,user_id,livemode,period_start,lead_id,session_id,phone,caller_id,max_seconds) values(p_call,p_user,p_live,a.period_start,p_lead,p_session,destination,number,limit_seconds);
 return jsonb_build_object('to',destination,'callerId',number,'maxSeconds',limit_seconds);
end $$;
create function public.dialer_consume_call(p_call uuid,p_parent text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.dialer_calls%rowtype;begin
 if p_parent is null or p_parent !~ '^CA[0-9a-fA-F]{32}$' then raise exception 'Invalid call reference';end if;
 select * into c from public.dialer_calls where id=p_call for update;
 if not found or c.finished or c.expires_at<=now() or (c.parent_sid is not null and c.parent_sid<>p_parent) or not private.dialer_session_active(c.user_id,c.session_id) or not public.dialer_entitled(c.user_id,c.livemode) or public.dialer_lead_phone(c.user_id,c.lead_id)<>c.phone or not exists(select 1 from public.dialer_numbers where user_id=c.user_id and livemode=c.livemode and phone=c.caller_id and state='active') then raise exception 'Call authorization expired or lead assignment changed';end if;
 update public.dialer_calls set parent_sid=p_parent where id=p_call;return jsonb_build_object('userId',c.user_id,'to',c.phone,'callerId',c.caller_id,'maxSeconds',c.max_seconds);
end $$;
create function public.dialer_record_call(p_parent text,p_child text,p_seconds integer,p_status text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c public.dialer_calls%rowtype;begin
 if p_parent is null or p_parent !~ '^CA[0-9a-fA-F]{32}$' or (p_child is not null and (p_child !~ '^CA[0-9a-fA-F]{32}$' or p_child=p_parent)) or p_seconds is null or p_seconds not between 0 and 7200 or p_status is null or p_status not in ('completed','busy','failed','no-answer','canceled') or (p_status<>'completed' and p_seconds<>0) then raise exception 'Invalid call duration';end if;
 select * into c from public.dialer_calls where parent_sid=p_parent for update;if not found then raise exception 'Call is not part of this dialer';end if;
 if c.finished then if c.child_sid is distinct from p_child or c.duration_seconds<>p_seconds or c.call_status<>p_status then raise exception 'Conflicting completed call';end if;return jsonb_build_object('recorded',false);end if;
 update public.dialer_calls set child_sid=p_child,duration_seconds=p_seconds,call_status=p_status,finished=true,finished_at=now() where id=c.id;
 return jsonb_build_object('recorded',true,'userId',c.user_id);
end $$;
create function public.dialer_quote_overage(p_user uuid,p_live boolean,p_start timestamptz,p_invoice text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare minutes integer;charge integer;existing public.dialer_overage_invoices%rowtype;begin
 perform 1 from public.dialer_periods where user_id=p_user and livemode=p_live and starts_at=p_start for update;if not found then raise exception 'Billing period unavailable';end if;
 if exists(select 1 from public.dialer_calls where user_id=p_user and livemode=p_live and period_start=p_start and parent_sid is not null and not finished) then raise exception 'Call reconciliation is still pending';end if;
 select coalesce(sum(used_minutes),0) into minutes from public.dialer_calls where user_id=p_user and livemode=p_live and period_start=p_start;charge:=greatest(minutes-5000,0)*3;
 insert into public.dialer_overage_invoices(invoice_id,user_id,livemode,period_start,amount_cents,used_minutes) values(p_invoice,p_user,p_live,p_start,charge,minutes) on conflict do nothing;
 select * into existing from public.dialer_overage_invoices where user_id=p_user and livemode=p_live and period_start=p_start;
 if existing.invoice_id<>p_invoice then raise exception 'Period has already been billed';end if;return to_jsonb(existing);
end $$;
do $$ declare r record;begin for r in select oid::regprocedure as fn from pg_proc where pronamespace='public'::regnamespace and proname in ('dialer_entitled','dialer_get_account','dialer_set_customer','dialer_sync_subscription','dialer_claim_checkout','dialer_set_checkout','dialer_set_limit','dialer_summary','dialer_select_number','dialer_begin_number','dialer_claim_number_purchase','dialer_finish_number','dialer_lead_phone','dialer_create_call','dialer_consume_call','dialer_record_call','dialer_quote_overage') loop execute 'revoke all on function '||r.fn||' from public,anon,authenticated';execute 'grant execute on function '||r.fn||' to service_role';end loop;end $$;

create function public.dialer_session_valid(p_user uuid,p_session uuid) returns boolean language sql security invoker set search_path='' as $$ select private.dialer_session_active(p_user,p_session); $$;
revoke all on function public.dialer_session_valid(uuid,uuid) from public,anon,authenticated;grant execute on function public.dialer_session_valid(uuid,uuid) to service_role;
create function public.dialer_period_minutes(p_user uuid,p_live boolean,p_start timestamptz) returns bigint language sql stable security invoker set search_path='' as $$ select coalesce(sum(used_minutes),0) from public.dialer_calls where user_id=p_user and livemode=p_live and period_start=p_start; $$; revoke all on function public.dialer_period_minutes(uuid,boolean,timestamptz) from public,anon,authenticated; grant execute on function public.dialer_period_minutes(uuid,boolean,timestamptz) to service_role;
