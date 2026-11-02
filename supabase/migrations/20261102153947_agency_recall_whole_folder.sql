-- Whole-folder snapshots stay on the server; each step uses the existing audited
-- recall operation. Bounds: 1M leads/preview, 5 previews/minute, 1K leads/step.
create table private.agency_recall_jobs(
 id uuid primary key default gen_random_uuid(),actor_id uuid not null,source text not null,
 mode text not null check(mode in ('folder','matching')),folder text,scope text not null,states text[],
 total integer not null default 0 check(total between 0 and 1000000),assigned integer not null default 0,
 processed integer not null default 0,returned integer not null default 0,skipped integer not null default 0,
 summary jsonb not null default '[]',created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '15 minutes',started_at timestamptz,
 finished_at timestamptz,cancelled boolean not null default false,
 check(processed=returned+skipped and processed between 0 and total)
);
create index agency_recall_jobs_actor on private.agency_recall_jobs(actor_id,source,created_at desc);
create table private.agency_recall_items(
 job_id uuid not null references private.agency_recall_jobs on delete cascade,
 position integer not null,lead_id uuid not null,version timestamptz not null,
 state text not null,assigned boolean not null,primary key(job_id,position),unique(job_id,lead_id)
);
alter table private.agency_recall_jobs enable row level security;
alter table private.agency_recall_items enable row level security;
revoke all on private.agency_recall_jobs,private.agency_recall_items from public,anon,authenticated;
-- Explicit deny policies document that access is exclusively via checked RPCs.
create policy no_direct_job_access on private.agency_recall_jobs to authenticated using(false) with check(false);
create policy no_direct_item_access on private.agency_recall_items to authenticated using(false) with check(false);

create function private.agency_recall_bulk_status(p_source text,p_job uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare job private.agency_recall_jobs;
begin
 perform private.assert_agency_recall_access(p_source);
 if p_job is null then
  select * into job from private.agency_recall_jobs where actor_id=auth.uid() and source=p_source
  and started_at is not null and finished_at is null and not cancelled and expires_at>now() order by created_at desc limit 1;
 else
  select * into job from private.agency_recall_jobs where id=p_job and actor_id=auth.uid() and source=p_source;
 end if;
 if not found then return null;end if;
 return to_jsonb(job)-'actor_id';
end $$;

create function private.agency_recall_bulk_prepare(p_source text,p_type text,p_scope text,p_states text[],p_mode text)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare job uuid; n integer; normalized text[];
begin
 perform private.assert_agency_recall_access(p_source);
 if p_mode is null or p_mode not in ('folder','matching') then raise exception 'Choose whole folder or all matching leads';end if;
 if p_scope is null or p_scope not in ('all','pool','assigned') then raise exception 'Choose which leads to include';end if;
 if p_mode='folder' and (p_type is null or p_scope<>'all' or p_states is not null) then raise exception 'Whole folder requires one folder, all states and all open leads';end if;
 if cardinality(p_states)>100 or array_position(p_states,null) is not null then raise exception 'Invalid state selection';end if;
 if p_states is not null then select coalesce(array_agg(distinct upper(btrim(s))),'{}') into normalized from unnest(p_states) s;end if;
 perform pg_advisory_xact_lock(hashtextextended('agency_recall_prepare:'||auth.uid(),0));
 if (select count(*) from private.agency_recall_jobs where actor_id=auth.uid() and created_at>now()-interval '1 minute')>=5 then raise exception 'Please wait a minute before preparing another preview';end if;
 if exists(select 1 from private.agency_recall_jobs where actor_id=auth.uid() and source=p_source and started_at is not null and finished_at is null and not cancelled and expires_at>now()) then raise exception 'Resume or stop the existing take-back for this agency first';end if;
 -- Discard expired preview metadata only, never leads or business history.
 delete from private.agency_recall_jobs where actor_id=auth.uid() and expires_at<now()-interval '1 day';
 insert into private.agency_recall_jobs(actor_id,source,mode,folder,scope,states) values(auth.uid(),p_source,p_mode,p_type,p_scope,normalized) returning id into job;
 insert into private.agency_recall_items(job_id,position,lead_id,version,state,assigned)
 select job,row_number() over(order by l.created_at,l.id)::integer,l.id,l.updated_at,upper(btrim(coalesce(l.state,''))),l.assigned_to is not null
 from public.leads l where l.division=p_source and l.status in ('assigned','unassigned')
 and (p_type is null or coalesce(l.lead_type,'')=p_type)
 and (p_scope='all' or (p_scope='pool' and l.assigned_to is null) or (p_scope='assigned' and l.assigned_to is not null))
 and (normalized is null or upper(btrim(coalesce(l.state,'')))=any(normalized))
 and not exists(select 1 from public.closed_business d where d.lead_id=l.id)
 order by l.created_at,l.id limit 1000001;
 get diagnostics n=row_count;
 if n>1000000 then raise exception 'More than 1,000,000 leads match. Select a folder or fewer states';end if;
 update private.agency_recall_jobs set total=n,
 assigned=(select count(*) from private.agency_recall_items where job_id=job and assigned),
 summary=(select coalesce(jsonb_agg(to_jsonb(t) order by t.state),'[]') from (
  select state,count(*) as count,count(*) filter(where assigned) as assigned from private.agency_recall_items where job_id=job group by state
 ) t) where id=job;
 return private.agency_recall_bulk_status(p_source,job);
end $$;

create function private.agency_recall_bulk_step(p_source text,p_job uuid,p_offset integer)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare job private.agency_recall_jobs; payload jsonb; n integer; moved integer:=0;
begin
 perform private.assert_agency_recall_access(p_source);
 select * into job from private.agency_recall_jobs where id=p_job and actor_id=auth.uid() and source=p_source for update;
 if not found then raise exception 'Take-back preview not found' using errcode='42501';end if;
 if job.cancelled then raise exception 'This take-back was stopped. Preview again';end if;
 if job.finished_at is not null then return private.agency_recall_bulk_status(p_source,p_job);end if;
 if job.expires_at<=now() then raise exception 'This preview expired. Preview the remaining leads again' using errcode='40001';end if;
 if p_offset is null or p_offset<0 or p_offset>job.processed then raise exception 'Take-back progress changed. Reopen the agency and resume';end if;
 -- A network retry of a completed step returns progress without doing more work.
 if p_offset<job.processed then return private.agency_recall_bulk_status(p_source,p_job);end if;
 n:=least(1000,job.total-job.processed);
 select coalesce(jsonb_agg(jsonb_build_object('id',i.lead_id,'updated_at',i.version) order by i.position),'[]') into payload
 from private.agency_recall_items i join public.leads l on l.id=i.lead_id
 where i.job_id=p_job and i.position>job.processed and i.position<=job.processed+n
 and l.division=p_source and l.updated_at=i.version and l.status in ('assigned','unassigned')
 and not exists(select 1 from public.closed_business d where d.lead_id=l.id);
 if jsonb_array_length(payload)>0 then moved:=private.agency_recall_commit(p_source,payload,gen_random_uuid());end if;
 update private.agency_recall_jobs set processed=processed+n,returned=returned+moved,skipped=skipped+n-moved,
 started_at=coalesce(started_at,now()),expires_at=case when started_at is null then now()+interval '24 hours' else expires_at end,
 finished_at=case when processed+n=total then now() else null end where id=p_job;
 if job.processed+n=job.total then
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'agency_bulk_recall_completed','agency',p_job::text,
  jsonb_build_object('source',p_source,'destination','owner','folder',job.folder,'states',job.states,'returned',job.returned+moved,'skipped',job.skipped+n-moved));
 end if;
 return private.agency_recall_bulk_status(p_source,p_job);
end $$;

create function private.agency_recall_bulk_stop(p_source text,p_job uuid)
returns jsonb language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
begin
 perform private.assert_agency_recall_access(p_source);
 update private.agency_recall_jobs set cancelled=true where id=p_job and actor_id=auth.uid() and source=p_source and finished_at is null;
 return private.agency_recall_bulk_status(p_source,p_job);
end $$;

create function public.agency_recall_bulk_status(p_source text,p_job uuid default null)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_bulk_status(p_source,p_job)$$;
create function public.agency_recall_bulk_prepare(p_source text,p_type text,p_scope text,p_states text[],p_mode text)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_bulk_prepare(p_source,p_type,p_scope,p_states,p_mode)$$;
create function public.agency_recall_bulk_step(p_source text,p_job uuid,p_offset integer)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_bulk_step(p_source,p_job,p_offset)$$;
create function public.agency_recall_bulk_stop(p_source text,p_job uuid)
returns jsonb language sql security invoker set search_path='' as $$select private.agency_recall_bulk_stop(p_source,p_job)$$;
revoke all on function private.agency_recall_bulk_status(text,uuid),public.agency_recall_bulk_status(text,uuid),
 private.agency_recall_bulk_prepare(text,text,text,text[],text),public.agency_recall_bulk_prepare(text,text,text,text[],text),
 private.agency_recall_bulk_step(text,uuid,integer),public.agency_recall_bulk_step(text,uuid,integer),
 private.agency_recall_bulk_stop(text,uuid),public.agency_recall_bulk_stop(text,uuid) from public,anon;
grant execute on function private.agency_recall_bulk_status(text,uuid),public.agency_recall_bulk_status(text,uuid),
 private.agency_recall_bulk_prepare(text,text,text,text[],text),public.agency_recall_bulk_prepare(text,text,text,text[],text),
 private.agency_recall_bulk_step(text,uuid,integer),public.agency_recall_bulk_step(text,uuid,integer),
 private.agency_recall_bulk_stop(text,uuid),public.agency_recall_bulk_stop(text,uuid) to authenticated;
notify pgrst,'reload schema';
