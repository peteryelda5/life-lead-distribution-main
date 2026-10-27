-- Never use the same shared caller ID twice in one three-line batch.
do $$
declare definition text; old_clause text:='where n.pool_id=p_pool and n.state=''active'' and n.phone<>leg.phone';
begin
 definition:=pg_get_functiondef('public.dialer_power_prepare_pool(uuid,uuid,uuid,text,text,uuid[],text[],numeric[],text,uuid)'::regprocedure);
 if position(old_clause in definition)=0 then raise exception 'Shared caller allocation changed; review migration.';end if;
 definition:=replace(definition,old_clause,old_clause||' and not exists(select 1 from public.dialer_parallel_legs used where used.session_id=p_id and used.caller_id=n.phone)');
 execute definition;
end $$;
