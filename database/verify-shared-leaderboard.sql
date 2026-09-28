do $$
declare a uuid; l uuid; m uuid; r jsonb; denied boolean;
begin
 a:=gen_random_uuid();l:=gen_random_uuid();
 select id into m from public.profiles where is_super_admin and active;
 begin
 insert into auth.users(id,email) values(a,'board-'||a||'@example.invalid'),(l,'board-'||l||'@example.invalid');
 insert into public.profiles(id,email,full_name,role,active,division) values(a,'board-'||a||'@example.invalid','Board Fixture','agent',true,'vivid_life'),(l,'board-'||l||'@example.invalid','Legacy Fixture','agent',true,'legacy_life') on conflict(id) do update set role='agent',active=true,division=excluded.division;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 r:=public.leaderboard_period('all','month',null);
 if not (r->'scopes') ? 'owner' or not (r->'scopes') ? 'vivid_life' or (r->'scopes') ? 'legacy_life' then raise exception 'Shared scopes wrong';end if;
 if public.chat_scopes()<>array['vivid_life'] then raise exception 'Chat widened';end if;
 if exists(select 1 from public.leads where division<>'vivid_life') then raise exception 'Lead access widened';end if;
 denied:=false;begin perform public.leaderboard_period('legacy_life','month',null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Legacy exposed';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',l,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 r:=public.leaderboard_period('all','month',null);
 if r->'scopes'<>'["legacy_life"]'::jsonb then raise exception 'Legacy board not isolated';end if;
 denied:=false;begin perform public.leaderboard_period('owner','month',null);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'Legacy can read shared board';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',m,'role','authenticated','aal','aal2')::text,true);
 set local role authenticated;
 r:=public.leaderboard_period('all','month',null);
 if (r->'scopes') ? 'legacy_life' then raise exception 'Master combined board includes Legacy';end if;
 reset role;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal1')::text,true);
 if cardinality(private.sales_board_divisions())<>0 then raise exception 'Agent MFA bypass';end if;
 perform set_config('request.jwt.claims','{}',true);
 if cardinality(private.sales_board_divisions())<>0 then raise exception 'Anonymous scope';end if;
 raise exception using errcode='ZX001',message='Rollback fixtures';
 exception when sqlstate 'ZX001' then null;end;
 reset role;
 if exists(select 1 from auth.users where id in (a,l)) then raise exception 'Fixtures persisted';end if;
end $$;
