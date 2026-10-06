alter table public.master_dialer_numbers drop constraint master_dialer_numbers_pkey;
alter table public.master_dialer_numbers add column number_slot smallint not null default 1 check(number_slot between 1 and 3);
alter table public.master_dialer_numbers add primary key(user_id,number_slot);
create function public.begin_master_number_activation(p_session_id uuid,p_expected_phone text,p_slot integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare pref public.dialer_number_preferences%rowtype; n public.master_dialer_numbers%rowtype;
begin
 if p_slot is null or p_slot not between 1 and 3 then raise exception 'Choose one of three included number slots'; end if;
 if not private.master_dialer_session_active(p_session_id) or not exists(select 1 from public.profiles where id='8139e230-055d-4247-8133-684ed817b4fa'::uuid and active and is_super_admin and role='admin' and not archived) then raise exception 'Master session is unavailable'; end if;
 select * into pref from public.dialer_number_preferences where user_id='8139e230-055d-4247-8133-684ed817b4fa'::uuid for update;
 if not found or pref.phone_number is distinct from p_expected_phone then raise exception 'Load and confirm your saved preferred number first'; end if;
 select * into n from public.master_dialer_numbers where user_id=pref.user_id and number_slot=p_slot for update;
 if found then return jsonb_build_object('phoneNumber',n.phone_number,'slot',n.number_slot,'state',n.state,'purchaseKey',n.purchase_key,'mayPurchase',false); end if;
 insert into public.master_dialer_numbers(user_id,phone_number,number_slot) values(pref.user_id,pref.phone_number,p_slot) returning * into n;
 return jsonb_build_object('phoneNumber',n.phone_number,'slot',n.number_slot,'state',n.state,'purchaseKey',n.purchase_key,'mayPurchase',true);
end $$;
create or replace function public.begin_master_number_activation(p_session_id uuid,p_expected_phone text)
returns jsonb language sql security invoker set search_path='' as $$select public.begin_master_number_activation(p_session_id,p_expected_phone,1);$$;
create function public.master_number_activation_status(p_slot integer)
returns jsonb language sql security invoker set search_path='' as $$
 select coalesce((select jsonb_build_object('phoneNumber',phone_number,'slot',number_slot,'state',state) from public.master_dialer_numbers where number_slot=p_slot),'{}'::jsonb)
 ||jsonb_build_object('numbers',coalesce((select jsonb_agg(jsonb_build_object('phoneNumber',phone_number,'slot',number_slot,'state',state) order by number_slot) from public.master_dialer_numbers),'[]'::jsonb),'includedNumbers',3);
$$;
create or replace function public.master_number_activation_status()
returns jsonb language sql security invoker set search_path='' as $$select public.master_number_activation_status(1);$$;
create or replace function public.active_master_dialer_number()
returns text language sql security invoker set search_path='' as $$
 select phone_number from public.master_dialer_numbers where state='active' order by number_slot limit 1;
$$;
create function public.active_master_dialer_number(p_slot integer)
returns text language sql security invoker set search_path='' as $$
 select phone_number from public.master_dialer_numbers where state='active' and number_slot=p_slot;
$$;
create function public.master_dialer_number_active(p_phone text)
returns boolean language sql security invoker set search_path='' as $$
 select exists(select 1 from public.master_dialer_numbers where state='active' and phone_number=p_phone);
$$;
revoke all on function public.begin_master_number_activation(uuid,text,integer),public.master_number_activation_status(integer),public.active_master_dialer_number(integer),public.master_dialer_number_active(text) from public,anon,authenticated;
grant execute on function public.begin_master_number_activation(uuid,text,integer),public.master_number_activation_status(integer),public.active_master_dialer_number(integer),public.master_dialer_number_active(text) to service_role;
