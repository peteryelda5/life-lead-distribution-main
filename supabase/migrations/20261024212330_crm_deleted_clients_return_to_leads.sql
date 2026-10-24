-- One recoverable lead per deleted CRM profile. The old closed lead/deal stays
-- intact so production history and the unique deal/lead relationship are preserved.
create table private.book_crm_lead_returns (
 profile_id uuid primary key,
 lead_id uuid not null unique,
 source_lead_id uuid,
 agent_id uuid not null references public.profiles(id),
 division text not null references public.divisions(id),
 actor_id uuid not null references public.profiles(id),
 transaction_id bigint not null default txid_current(),
 completed boolean not null default false,
 created_at timestamptz not null default now()
);
alter table private.book_crm_lead_returns enable row level security;
revoke all on private.book_crm_lead_returns from public,anon,authenticated;
create index book_crm_lead_returns_agent on private.book_crm_lead_returns(agent_id);
create index book_crm_lead_returns_actor on private.book_crm_lead_returns(actor_id);
create index book_crm_lead_returns_division on private.book_crm_lead_returns(division);

-- An exact, transaction-scoped permit created only by the authorized deletion RPC.
-- It cannot be supplied through a JWT, a GUC, a lead field or a direct table write.
create function private.book_crm_lead_return_permitted(p_lead public.leads) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.book_crm_lead_returns r
 where r.lead_id=p_lead.id and r.agent_id=p_lead.assigned_to and r.division=p_lead.division
 and r.actor_id=auth.uid() and r.transaction_id=txid_current() and not r.completed
 and p_lead.status='assigned');
$$;
revoke all on function private.book_crm_lead_return_permitted(public.leads) from public,anon,authenticated;

create function private.book_crm_return_lead(p_profile uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles; owner_profile public.profiles; origin public.leads;
 contact jsonb; headers jsonb; cells jsonb; item record; label text; key text; normalized text;
 seen text[]:='{}'; i integer; lead_id uuid:=gen_random_uuid(); agency text; reused boolean:=false;
 client_name text; notes text; result jsonb;
begin
 select * into person from private.book_crm_profiles where id=p_profile;
 if not found or not private.book_is_unlocked() or not private.book_crm_can_access(person.agent_id,null) then
  raise exception 'Client not available to your account' using errcode='42501';
 end if;
 select * into owner_profile from public.profiles where id=person.agent_id;
 if not owner_profile.active or owner_profile.archived or not exists(select 1 from public.divisions where id=owner_profile.division and not archived) then
  raise exception 'Reactivate or transfer this client''s agent before returning the client to leads.';
 end if;
 -- Prefer a still-open exact linked lead; never match unrelated people by phone/name.
 select l.* into origin from public.leads l join public.closed_business d on d.lead_id=l.id
 join private.book_crm_clients c on c.deal_id=d.id
 where c.profile_id=p_profile and l.assigned_to=person.agent_id
 order by (l.status='assigned') desc,l.created_at,l.id limit 1 for update of l;
 agency:=coalesce(origin.division,owner_profile.division);
 if origin.id is not null and origin.status='assigned' then lead_id:=origin.id;reused:=true;end if;
 contact:=coalesce(private.book_crm_lead_contact(origin),'{}');
 for item in select * from jsonb_each(coalesce(person.details,'{}')) loop
  if item.value<>'null'::jsonb and nullif(trim(item.value#>>'{}'),'') is not null then contact:=jsonb_set(contact,array[item.key],item.value);end if;
 end loop;
 client_name:=coalesce(nullif(contact->>'client_name',''),'Client from CRM');
 contact:=contact||jsonb_build_object('client_name',client_name,'first_name',split_part(client_name,' ',1),
 'last_name',ltrim(substr(client_name,length(split_part(client_name,' ',1))+1)));
 headers:=coalesce(origin.csv_headers,'[]');cells:=coalesce(origin.csv_values,'[]');
 if jsonb_typeof(headers)<>'array' then headers:='[]';end if;
 if jsonb_typeof(cells)<>'array' then cells:='[]';end if;
 while jsonb_array_length(cells)<jsonb_array_length(headers) loop cells:=cells||jsonb_build_array('');end loop;
 for i in 0..jsonb_array_length(headers)-1 loop
  normalized:=regexp_replace(lower(headers->>i),'[^a-z0-9]','','g');
  key:=case
   when normalized in ('firstname','first','givenname') then 'first_name'
   when normalized in ('lastname','last','surname','familyname') then 'last_name'
   when normalized in ('name','fullname','clientname','insuredname') then 'client_name'
   when normalized in ('phone','phonenumber','mobile','mobilephone','cell','cellphone','telephone') then 'phone'
   when normalized in ('email','emailaddress') then 'email'
   when normalized in ('state','st','statecode') then 'state'
   when normalized in ('address','addressline1','street','streetaddress') then 'address_line1'
   when normalized in ('city','town') then 'city'
   when normalized in ('zip','zipcode','postalcode') then 'zip'
   when normalized in ('alternatephone','secondaryphone') then 'alternate_phone'
   when normalized in ('dob','dateofbirth','birthdate') then 'date_of_birth'
   when normalized='mortgagebalance' then 'mortgage_balance' end;
  if key is not null then
   seen:=array_append(seen,key);
   if key='client_name' then seen:=seen||array['first_name','last_name'];end if;
   if nullif(contact->>key,'') is not null then cells:=jsonb_set(cells,array[i::text],to_jsonb(contact->>key));end if;
  end if;
 end loop;
 for item in select * from (values ('first_name','First Name'),('last_name','Last Name'),('phone','Phone'),
 ('email','Email'),('state','State'),('address_line1','Address'),('address_line2','Address Line 2'),('city','City'),
 ('zip','Zip'),('alternate_phone','Alternate Phone'),('date_of_birth','Date of Birth'),('mortgage_balance','Mortgage Balance')) v(k,l) loop
  if not item.k=any(seen) and nullif(contact->>item.k,'') is not null then
   headers:=headers||jsonb_build_array(item.l);cells:=cells||jsonb_build_array(contact->>item.k);
  end if;
 end loop;
 select concat_ws(E'\n\n',nullif(origin.call_notes,''),'Returned from CRM on '||(now() at time zone 'America/Detroit')::date||'. Previous production history retained.',
  (select string_agg(concat_ws(' — ',c.carrier,c.policy_type,nullif(c.policy_number,''),nullif(c.notes,'')),E'\n' order by c.created_at,c.id) from private.book_crm_clients c where c.profile_id=p_profile),
  (select string_agg(a.body,E'\n' order by a.created_at,a.id) from private.book_crm_activity a join private.book_crm_clients c on c.id=a.client_id where c.profile_id=p_profile and a.kind='note'),
  (select string_agg('Open task: '||t.title||' (due '||t.due_at::date||')',E'\n' order by t.due_at,t.id) from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_profile and t.completed_at is null)) into notes;
 insert into private.book_crm_lead_returns(profile_id,lead_id,source_lead_id,agent_id,division,actor_id)
 values(p_profile,lead_id,origin.id,person.agent_id,agency,auth.uid());
 if reused then
  update public.leads set first_name=contact->>'first_name',last_name=contact->>'last_name',
   phone=contact->>'phone',email=contact->>'email',state=contact->>'state',csv_headers=headers,csv_values=cells,call_notes=notes
  where id=lead_id;
 else
  insert into public.leads(id,first_name,last_name,phone,email,state,source,notes,status,assigned_to,assigned_at,
   lead_type,csv_filename,csv_headers,csv_values,agent_status,call_notes,owner_admin_id,division,uploaded_by,is_dead_number)
  values(lead_id,contact->>'first_name',contact->>'last_name',contact->>'phone',contact->>'email',contact->>'state',
   coalesce(origin.source,'CRM return'),origin.notes,'assigned',person.agent_id,now(),
   case when origin.id is not null then origin.lead_type else 'Returned from CRM' end,origin.csv_filename,headers,cells,
   case when origin.is_dead_number then 'dead_number' else 'call_back' end,notes,
   coalesce(origin.owner_admin_id,owner_profile.created_by_admin_id,case when owner_profile.role='admin' then owner_profile.id end),
   agency,coalesce(origin.uploaded_by,person.agent_id),coalesce(origin.is_dead_number,false));
  if agency<>owner_profile.division and owner_profile.role='agent' then
   insert into private.agent_portable_leads(lead_id,agent_id,origin_division) values(lead_id,person.agent_id,agency);
  end if;
 end if;
 update private.book_crm_lead_returns set completed=true where profile_id=p_profile;
 return jsonb_build_object('returned_lead_id',lead_id,'returned_agent_id',person.agent_id,'reused_lead',reused,
  'returned_folder',case when origin.id is not null then origin.lead_type else 'Returned from CRM' end);
end;$$;
revoke all on function private.book_crm_return_lead(uuid) from public,anon,authenticated;

-- Preserve existing upload/agency rules; permit only the exact authorized CRM return.
create or replace function private.stamp_lead_uploader() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' and private.book_crm_lead_return_permitted(new) then return new;end if;
 if tg_op='INSERT' then
  new.uploaded_by:=auth.uid();
  if private.is_team_leader() then
   if new.division is distinct from private.leader_division() then raise exception 'Upload leads only to your division' using errcode='42501'; end if;
   new.status:='unassigned';new.assigned_to:=null;new.assigned_at:=null;new.owner_admin_id:=null;
  end if;
 elsif new.uploaded_by is distinct from old.uploaded_by then raise exception 'Lead uploader cannot be changed'; end if;
 return new;
end $$;

-- Preserve existing upload/agency rules; permit only the exact authorized CRM return.
CREATE OR REPLACE FUNCTION public.set_lead_division_on_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if tg_op='INSERT' and private.book_crm_lead_return_permitted(new) then return new;end if;
  if new.division is null or btrim(new.division)='' then
    if public.is_super_admin() then
      new.division := public.current_admin_division();
    elsif public.is_admin() then
      new.division := public.current_admin_division();
    end if;
  end if;
  if not exists(select 1 from public.divisions where id=new.division) then
    raise exception 'Invalid division';
  end if;
  if public.is_admin() and not public.is_super_admin() and not public.admin_can_access_division(new.division) then
    raise exception 'You cannot add leads to another division';
  end if;
  if public.is_super_admin() and new.division not in ('owner','vivid_life') then
    raise exception 'Master can add leads only to Vivid Life or Master' using errcode='42501';
  end if;
  return new;
end;
$function$;

-- Preserve existing upload/agency rules; permit only the exact authorized CRM return.
CREATE OR REPLACE FUNCTION public.enforce_lead_division()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare caller_role public.user_role; caller_super boolean; caller_div text; agent_div text;
begin
 if tg_op in ('INSERT','UPDATE') and private.book_crm_lead_return_permitted(new) then return new;end if;
 if tg_op='UPDATE' and new.division is distinct from old.division then
  if not (
   (private.can_transfer_lead_pool(old.division,new.division) and old.division<>'legacy_life' and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null)
   or (private.can_recall_agency_pool(old.division,new.division) and old.status='unassigned' and old.assigned_to is null and new.status='unassigned' and new.assigned_to is null and not exists(select 1 from public.closed_business b where b.lead_id=old.id))
   or (old.status='closed' and new.status='closed' and old.assigned_to is not null and new.assigned_to=old.assigned_to and public.admin_can_access_division(old.division) and public.admin_can_access_division(new.division) and exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='agent' and p.division=new.division and not coalesce(p.archived,false)))
  ) then raise exception 'Lead division change is not allowed outside an authorized pool or agent transfer.' using errcode='42501'; end if;
 end if;
 if auth.uid() is not null then
  select p.role,p.is_super_admin,p.division into caller_role,caller_super,caller_div from public.profiles p where p.id=auth.uid() and p.active=true;
  if caller_role='admin'::public.user_role then
   if coalesce(caller_super,false) then
    if new.division is null then new.division:=caller_div; end if;
    if tg_op='INSERT' and new.division not in ('owner','vivid_life') then raise exception 'Master can add or move leads only to Vivid Life or Master' using errcode='42501';end if;
    if tg_op='INSERT' and new.owner_admin_id is null then new.owner_admin_id:=auth.uid();end if;
   else
    if caller_div is null then raise exception 'Admin division is not configured';end if;
    if tg_op='UPDATE' and not public.admin_can_access_division(old.division) then raise exception 'You cannot manage leads in another division' using errcode='42501';end if;
    if not public.admin_can_access_division(new.division) then raise exception 'You cannot add or move leads to another division' using errcode='42501';end if;
    if tg_op='INSERT' then new.owner_admin_id:=auth.uid();end if;
   end if;
  end if;
 end if;
 if new.division is null then new.division:='owner';end if;
 if new.assigned_to is not null then
  if exists(select 1 from public.profiles p where p.id=new.assigned_to and p.role='admin') then
   if not private.admin_can_receive_lead(new.assigned_to,new.division) then
    raise exception 'Admin recipient cannot access this agency' using errcode='42501';
   end if;
  else
  select p.division into agent_div from public.profiles p where p.id=new.assigned_to and p.role='agent'::public.user_role;
  if agent_div is null or (agent_div<>new.division and not (
   tg_op='UPDATE' and new.status in ('assigned','closed') and new.division=old.division
   and exists(select 1 from private.agent_portable_leads x where x.lead_id=new.id and x.agent_id=new.assigned_to and x.origin_division=new.division)
  )) then raise exception 'Lead and agent must belong to the same division';end if;
  end if;
 end if;
 return new;
end $function$;

-- A lead must be returned successfully before any CRM records are deleted.
create or replace function private.book_crm_profile_delete(p_id uuid,p_expected_updated_at timestamptz,p_expected_policies jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person private.book_crm_profiles%rowtype; policy_row record; current_versions jsonb; expected_versions jsonb; snapshot jsonb; n integer; returned jsonb; prior private.book_crm_lead_returns;
begin
 perform public.require_portal_onboarding();
 if auth.uid() is null or not private.book_is_unlocked() then raise exception 'Book of Business is locked. Enter your PIN.' using errcode='42501';end if;
 if p_id is null or p_expected_policies is null or jsonb_typeof(p_expected_policies)<>'array' then raise exception 'Reopen the client before deleting it';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,49413));
 select * into prior from private.book_crm_lead_returns where profile_id=p_id and completed;
 if found then
  if prior.actor_id<>auth.uid() or not private.book_crm_can_access(prior.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
  return jsonb_build_object('ok',true,'id',p_id,'returned_lead_id',prior.lead_id,'returned_agent_id',prior.agent_id,'replayed',true);
 end if;
 select * into person from private.book_crm_profiles where id=p_id;
 if not found or not private.book_crm_can_access(person.agent_id,null) then raise exception 'Client not available to your account' using errcode='42501';end if;
 -- Same profile-before-policy lock order used by Add policy. Lock rows before the
 -- profile row so legacy contact synchronization can finish without a lock cycle.
 for policy_row in select id from private.book_crm_clients where profile_id=p_id order by id loop
  perform pg_advisory_xact_lock(hashtextextended(policy_row.id::text,49412));
  perform 1 from private.book_crm_clients where id=policy_row.id for update;
 end loop;
 select * into person from private.book_crm_profiles where id=p_id for update;
 if exists(select 1 from private.book_crm_clients c where c.profile_id=p_id and not private.book_crm_can_access(c.agent_id,c.deal_id)) then raise exception 'Not all policies are available to your account' using errcode='42501';end if;
 perform 1 from public.closed_business d where d.id in (select deal_id from private.book_crm_clients where profile_id=p_id) order by d.id for update;
 select jsonb_agg(jsonb_build_object('id',id,'updated_at',updated_at,'deal_version',deal_version) order by id),count(*)
 into current_versions,n from private.book_crm_records where profile_id=p_id;
 select jsonb_agg(value order by value->>'id') into expected_versions from jsonb_array_elements(p_expected_policies);
 if n=0 or person.updated_at is distinct from p_expected_updated_at or current_versions is distinct from expected_versions then
  raise sqlstate 'PT409' using message='Client or policies changed. Reopen the client before deleting it.';
 end if;
 perform 1 from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id order by t.id for update of t;
 select jsonb_build_object('profile',to_jsonb(person),
  'policies',(select jsonb_agg(to_jsonb(c) order by c.id) from private.book_crm_clients c where c.profile_id=p_id),
  'tasks',coalesce((select jsonb_agg(to_jsonb(t)) from private.book_crm_tasks t join private.book_crm_clients c on c.id=t.client_id where c.profile_id=p_id),'[]'::jsonb),
  'activity',coalesce((select jsonb_agg(to_jsonb(a)) from private.book_crm_activity a join private.book_crm_clients c on c.id=a.client_id where c.profile_id=p_id),'[]'::jsonb),
  'carrier_statuses',coalesce((select jsonb_agg(to_jsonb(s)) from private.book_crm_carrier_status s join private.book_crm_clients c on c.id=s.policy_id where c.profile_id=p_id),'[]'::jsonb)) into snapshot;
 returned:=private.book_crm_return_lead(p_id);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'crm_client_deleted','crm_profile',p_id::text,jsonb_build_object('before',snapshot,'policy_count',n,'production_preserved',true,'lead_return',returned));
 delete from private.book_crm_clients where profile_id=p_id;
 delete from private.book_crm_profiles where id=p_id;
 return jsonb_build_object('ok',true,'id',p_id,'deleted_policies',n)||returned;
end;$$;
