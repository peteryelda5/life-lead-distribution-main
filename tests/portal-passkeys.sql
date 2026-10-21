-- Run only after the approved migration. Synthetic rows roll back in full.
begin;
set local statement_timeout='30s';
do $$
declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();sa uuid:=gen_random_uuid();sb uuid:=gen_random_uuid();sa2 uuid:=gen_random_uuid();
 cid uuid;key_id text:='fixture-'||gen_random_uuid();r jsonb;rejected boolean;n bigint;
begin
 if has_function_privilege('authenticated','public.portal_passkey_manage(uuid,uuid,text,text,jsonb)','execute')
 or has_function_privilege('anon','private.portal_passkey_session_valid(uuid,uuid)','execute')
 or has_function_privilege('authenticated','public.portal_passkey_reset(uuid)','execute')
 or has_table_privilege('authenticated','private.portal_passkeys','select')
 or has_table_privilege('service_role','private.portal_passkey_sessions','insert') then raise exception 'Passkey privilege exposed';end if;
 if not has_function_privilege('service_role','public.portal_passkey_manage(uuid,uuid,text,text,jsonb)','execute') then raise exception 'Server privilege missing';end if;
 insert into auth.users(id,email) values(a,a||'@example.invalid'),(b,b||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division)
 values(a,a||'@example.invalid','Face ID Fixture','agent',true,'vivid_life'),(b,b||'@example.invalid','Other Face ID Fixture','agent',true,'legacy_life')
 on conflict(id) do update set role='agent',active=true,archived=false,division=excluded.division;
 insert into auth.sessions(id,user_id,aal,created_at) values(sa,a,'aal1',now()),(sb,b,'aal1',now()),(sa2,a,'aal1',now());
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',sa,'role','authenticated','aal','aal1')::text,true);
 if private.verified_portal_session() then raise exception 'Password alone admitted';end if;
 rejected:=false;begin perform public.portal_passkey_manage(a,sb,'aal2','status');exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Foreign session admitted';end if;
 rejected:=false;begin perform public.portal_passkey_manage(a,sa,'aal1','register_options',jsonb_build_object('challenge',repeat('A',43)));exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Unverified enrollment allowed';end if;
 r:=public.portal_passkey_manage(a,sa,'aal2','register_options',jsonb_build_object('challenge',repeat('A',43)));cid:=(r->>'id')::uuid;
 rejected:=false;begin perform public.portal_passkey_manage(a,sa,'aal2','register_finish',jsonb_build_object('id',cid,'credential',key_id));exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Untaken challenge completed';end if;
 perform public.portal_passkey_manage(a,sa,'aal2','take',jsonb_build_object('id',cid,'kind','register'));
 perform public.portal_passkey_manage(a,sa,'aal2','register_finish',jsonb_build_object('id',cid,'credential',key_id,'public_key',repeat('K',100),'counter',0,'transports',jsonb_build_array('internal'),'name','Test iPhone'));
 rejected:=false;begin perform public.portal_passkey_manage(a,sa,'aal2','take',jsonb_build_object('id',cid,'kind','register'));exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Challenge replay allowed';end if;
 r:=public.portal_passkey_manage(a,sa,'aal1','authenticate_options',jsonb_build_object('challenge',repeat('B',43)));cid:=(r->>'id')::uuid;
 rejected:=false;begin perform public.portal_passkey_manage(a,sa2,'aal1','take',jsonb_build_object('id',cid,'kind','authenticate','credential',key_id));exception when insufficient_privilege then rejected:=true;end;
 if not rejected then raise exception 'Challenge escaped session';end if;
 perform public.portal_passkey_manage(a,sa,'aal1','take',jsonb_build_object('id',cid,'kind','authenticate','credential',key_id));
 perform public.portal_passkey_manage(a,sa,'aal1','authenticate_finish',jsonb_build_object('id',cid,'credential',key_id,'counter',1,'previous_counter',0));
 if not private.verified_portal_session() or not public.is_active_agent() then raise exception 'Valid Face ID session denied';end if;
 if not('vivid_life'=any(private.sales_board_divisions())) or 'legacy_life'=any(private.sales_board_divisions()) then raise exception 'Agency scope changed';end if;
 set local role authenticated;
 perform public.require_portal_mfa();
 select count(*) into n from public.leads where assigned_to is distinct from a;
 if n<>0 then raise exception 'Another agent leads exposed';end if;
 reset role;
 if private.portal_passkey_session_valid(a,sa2) or private.portal_passkey_session_valid(b,sa) then raise exception 'Proof escaped account/session';end if;
 update private.portal_passkey_sessions set expires_at=now()-interval '1 second' where session_id=sa;
 if private.verified_portal_session() then raise exception 'Expired proof accepted';end if;
 update private.portal_passkey_sessions set expires_at=now()+interval '1 hour' where session_id=sa;
 update public.profiles set active=false where id=a;
 if private.verified_portal_session() then raise exception 'Disabled user accepted';end if;
 update public.profiles set active=true where id=a;
 update auth.sessions set not_after=now()-interval '1 second' where id=sa;
 if private.verified_portal_session() then raise exception 'Expired Auth session accepted';end if;
 update auth.sessions set not_after=null where id=sa;
 perform public.portal_passkey_manage(b,sb,'aal2','remove',jsonb_build_object('credential',key_id));
 if not private.verified_portal_session() then raise exception 'Foreign user removed credential';end if;
 perform public.portal_passkey_manage(a,sa,'aal1','remove',jsonb_build_object('credential',key_id));
 if private.verified_portal_session() or exists(select 1 from private.portal_passkey_sessions where session_id=sa) then raise exception 'Revoked credential still authorizes';end if;
 -- Deleting a native session must cascade proofs/challenges. TOTP still works.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',sa,'role','authenticated','aal','aal2')::text,true);
 if not private.verified_portal_session() then raise exception 'Existing TOTP login broken';end if;
 perform public.portal_passkey_manage(a,sa,'aal2','register_options',jsonb_build_object('challenge',repeat('C',43)));
 delete from auth.sessions where id=sa;
 if exists(select 1 from private.portal_passkey_challenges where session_id=sa) then raise exception 'Session revocation left challenges';end if;
end $$;
rollback;
