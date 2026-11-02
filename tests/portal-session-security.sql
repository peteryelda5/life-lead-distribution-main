-- Isolated synthetic identities only. Caller must wrap this file in BEGIN / ROLLBACK.
DO $test$
DECLARE a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); other_session uuid:=gen_random_uuid();
BEGIN
 INSERT INTO auth.users(id,email) VALUES(a,a||'@example.invalid'),(b,b||'@example.invalid');
 INSERT INTO public.profiles(id,email,full_name,role,active,archived,division)
 VALUES(a,a||'@example.invalid','Security fixture A','agent',true,false,'vivid_life'),
       (b,b||'@example.invalid','Security fixture B','agent',true,false,'legacy_life');
 INSERT INTO auth.sessions(id,user_id,aal,created_at) VALUES(s,a,'aal2',now()),(other_session,b,'aal2',now());
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',s,'role','authenticated','aal','aal2')::text,true);
 IF NOT private.verified_portal_session() THEN RAISE EXCEPTION 'Valid authenticator session denied';END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',s,'role','authenticated','aal','aal1')::text,true);
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Password-only session admitted';END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',other_session,'role','authenticated','aal','aal2')::text,true);
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Foreign session admitted';END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',s,'role','authenticated','aal','aal2')::text,true);
 UPDATE auth.sessions SET not_after=now()-interval '1 second' WHERE id=s;
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Expired session admitted';END IF;
 UPDATE auth.sessions SET not_after=NULL WHERE id=s;
 UPDATE public.profiles SET active=false WHERE id=a;
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Disabled account admitted';END IF;
 UPDATE public.profiles SET active=true WHERE id=a;
 DELETE FROM auth.sessions WHERE id=s;
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Revoked authenticator session admitted';END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
 IF private.verified_portal_session() THEN RAISE EXCEPTION 'Missing session claim admitted';END IF;
 IF has_function_privilege('anon','public.admin_lead_page(text,text,text,text,integer,integer)','execute')
  OR has_function_privilege('anon','public.admin_delete_all_leads_scoped(text,boolean)','execute')
  OR NOT has_function_privilege('authenticated','public.admin_lead_page(text,text,text,text,integer,integer)','execute')
  OR NOT has_function_privilege('anon','public.check_portal_request()','execute') THEN RAISE EXCEPTION 'RPC privilege regression';END IF;
END $test$;
SELECT 'PASS: valid MFA, password-only rejection, account binding, expiry, disable, revocation, missing claim and RPC grants' AS result;
