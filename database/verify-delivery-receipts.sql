do $$
declare m uuid; legacy_admin uuid; agent uuid:=gen_random_uuid(); lid uuid; lid2 uuid; count_before bigint; rid bigint; rows jsonb; denied boolean;
begin
 select id into m from public.profiles where is_super_admin and active;
 select id into legacy_admin from public.profiles where role='admin' and division='legacy_life' and active and not coalesce(archived,false) limit 1;
 begin
 perform set_config('request.jwt.claims','{}',true);
 insert into auth.users(id,email) values(agent,agent||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division) values(agent,agent||'@example.invalid','Receipt Fixture','agent',true,'legacy_life') on conflict(id) do update set role='agent',active=true,division='legacy_life';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 insert into public.leads(first_name,last_name,division) values('Receipt','Fixture','owner') returning id into lid;
 insert into public.leads(first_name,last_name,division) values('Receipt','Fixture2','owner') returning id into lid2;
 select count(*) into count_before from public.lead_delivery_receipts;
 perform public.send_leads_to_recipient(array[lid,lid2],'owner','legacy_life',agent);
 if (select count(*) from public.lead_delivery_receipts)<>count_before+1 then raise exception 'Direct delivery has duplicate/missing receipt';end if;
 select id into rid from public.lead_delivery_receipts where lead_ids @> array[lid] and source_division='owner' and destination_division='legacy_life' and recipient_id=agent and sender_id=m and lead_count=2;
 if rid is null then raise exception 'Receipt details incorrect';end if;
 update public.leads set call_notes='Fixture note' where id=lid;
 if (select count(*) from public.lead_delivery_receipts)<>count_before+1 then raise exception 'Ordinary edit created delivery';end if;
 rows:=public.delivery_receipts_page('all',null,lid);
 if jsonb_array_length(rows)<>1 or (rows->0->>'lead_count')::int<>2 then raise exception 'Receipt lookup failed';end if;
 denied:=false;begin delete from public.lead_delivery_receipts where id=rid;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Client can delete receipts';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',legacy_admin,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 if jsonb_array_length(public.delivery_receipts_page('legacy_life',null,lid))<>1 then raise exception 'Receiving admin cannot read receipt';end if;
 denied:=false;begin perform public.delivery_receipts_page('owner',null,null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Division isolation failed';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',agent,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 denied:=false;begin perform public.delivery_receipts_page('all',null,null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Agent read admin receipts';end if;
 reset role;
 raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id=agent) or exists(select 1 from public.leads where id in(lid,lid2)) then raise exception 'Fixtures persisted';end if;
end $$;
