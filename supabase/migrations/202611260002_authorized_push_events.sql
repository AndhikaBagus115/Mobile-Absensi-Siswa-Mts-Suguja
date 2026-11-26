-- Run after 202611260001. Triggers queue committed events; they send no messages.
begin;
create table if not exists siab_private.push_identities (
  user_id uuid primary key references auth.users(id) on delete cascade,
  external_id text not null unique default
    (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  created_at timestamptz not null default now()
);
create table if not exists siab_private.push_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check(event_type in ('attendance','letter_decision')),
  record_id bigint not null,
  siswa_id bigint not null references public.siswa(id) on delete cascade,
  version text not null,
  status text not null default 'pending'
    check(status in ('pending','sending','sent','failed','superseded')),
  attempts integer not null default 0,
  lease_until timestamptz,
  provider_id text,
  created_at timestamptz not null default now(),
  unique(event_type,record_id,version)
);
create index if not exists siab_push_events_lookup on siab_private.push_events(event_type,record_id,created_at desc);
create table if not exists siab_private.push_rate_limits (
  actor_id uuid not null references auth.users(id) on delete cascade,
  minute timestamptz not null,
  requests integer not null,
  primary key(actor_id,minute)
);
alter table siab_private.push_identities enable row level security;
alter table siab_private.push_events enable row level security;
alter table siab_private.push_rate_limits enable row level security;
revoke all on siab_private.push_identities,siab_private.push_events,siab_private.push_rate_limits
  from public,anon,authenticated;

create or replace function siab_private.event_version(record_data jsonb)
returns text language sql immutable set search_path='' as $$
  select encode(sha256(convert_to(record_data::text,'UTF8')),'hex');
$$;
create or replace function siab_private.queue_push_event()
returns trigger language plpgsql security definer set search_path='' as $$
declare kind text; row_data jsonb; digest text;
begin
  row_data := to_jsonb(new);
  kind := case when tg_table_name='absensi' then 'attendance' else 'letter_decision' end;
  if kind='letter_decision' and coalesce(row_data->>'status','menunggu')
      not in ('disetujui','ditolak') then return new; end if;
  if tg_op='UPDATE' and row_data=to_jsonb(old) then return new; end if;
  digest := siab_private.event_version(row_data);
  update siab_private.push_events set status='superseded'
    where event_type=kind and record_id=new.id and version<>digest
      and status in ('pending','failed');
  insert into siab_private.push_events(event_type,record_id,siswa_id,version)
    values(kind,new.id,new.siswa_id,digest) on conflict(event_type,record_id,version) do nothing;
  return new;
end $$;
drop trigger if exists siab_queue_attendance_push on public.absensi;
create trigger siab_queue_attendance_push after insert or update on public.absensi
  for each row execute function siab_private.queue_push_event();
drop trigger if exists siab_queue_letter_push on public.surat;
create trigger siab_queue_letter_push after insert or update on public.surat
  for each row execute function siab_private.queue_push_event();

-- There is no student/NIS alias and no client-selected account ID.
create or replace function siab_private.my_push_identity()
returns text language plpgsql security definer set search_path='' as $$
declare identity_value text;
begin
  if auth.uid() is null or not (siab_private.is_staff() or siab_private.is_parent()) then
    raise exception using errcode='42501',message='Verified enrolled account required';
  end if;
  insert into siab_private.push_identities(user_id) values(auth.uid()) on conflict(user_id) do nothing;
  select external_id into identity_value from siab_private.push_identities where user_id=auth.uid();
  return identity_value;
end $$;
create or replace function public.siab_my_push_identity()
returns text language sql security invoker set search_path='' as $$
  select siab_private.my_push_identity();
$$;

-- Only Edge Function service-role calls reach this helper. actor_id comes from
-- Auth getUser(), never from the caller request body or JWT user_metadata.
create or replace function siab_private.claim_push_event(
  p_actor_id uuid,p_event_type text,p_record_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_record jsonb; student bigint; job siab_private.push_events%rowtype;
  recipients jsonb; request_count integer; current_minute timestamptz;
begin
  if not siab_private.is_staff(p_actor_id) or p_event_type is null or p_event_type not in ('attendance','letter_decision')
      or p_record_id is null or p_record_id<=0 then
    raise exception using errcode='42501',message='Event access denied';
  end if;
  if p_event_type='attendance' then
    select to_jsonb(a) into current_record from public.absensi a where a.id=p_record_id;
  else
    select to_jsonb(s) into current_record from public.surat s where s.id=p_record_id;
  end if;
  student := (current_record->>'siswa_id')::bigint;
  if current_record is null or student is null or not siab_private.can_write_student(student,p_actor_id) then
    raise exception using errcode='42501',message='Event access denied';
  end if;
  current_minute := date_trunc('minute',clock_timestamp());
  insert into siab_private.push_rate_limits(actor_id,minute,requests)
    values(p_actor_id,current_minute,1) on conflict(actor_id,minute)
    do update set requests=siab_private.push_rate_limits.requests+1 returning requests into request_count;
  if request_count>120 then raise exception using errcode='P0001',message='RATE_LIMITED'; end if;
  delete from siab_private.push_rate_limits where minute<current_minute-interval '1 day';
  select * into job from siab_private.push_events e where e.event_type=p_event_type
    and e.record_id=p_record_id and e.version=siab_private.event_version(current_record)
    and e.created_at>now()-interval '1 day' order by e.created_at desc limit 1 for update;
  if job.id is null then return jsonb_build_object('status','no_event'); end if;
  if job.status='sent' then return jsonb_build_object('status','already_sent'); end if;
  if job.status='sending' and job.lease_until>now() then
    return jsonb_build_object('status','in_progress');
  end if;
  select jsonb_agg(distinct pi.external_id) into recipients
    from public.siab_wali_students ws join public.siab_wali_accounts w
      on w.user_id=ws.wali_id and w.active
    join siab_private.push_identities pi on pi.user_id=w.user_id
    where ws.siswa_id=student;
  if recipients is null then return jsonb_build_object('status','no_recipients'); end if;
  update siab_private.push_events set status='sending',attempts=attempts+1,
    lease_until=now()+interval '30 seconds' where id=job.id;
  return jsonb_build_object('status','ready','event_id',job.id,
    'recipient_external_ids',recipients,'siswa_id',student);
end $$;
create or replace function public.siab_claim_push_event(
  p_actor_id uuid,p_event_type text,p_record_id bigint)
returns jsonb language sql security invoker set search_path='' as $$
  select siab_private.claim_push_event(p_actor_id,p_event_type,p_record_id);
$$;
create or replace function siab_private.finish_push_event(
  p_event_id uuid,p_success boolean,p_provider_id text)
returns void language sql security definer set search_path='' as $$
  update siab_private.push_events set status=case when p_success then 'sent' else 'failed' end,
    provider_id=case when p_success then left(p_provider_id,100) else null end,
    lease_until=null where id=p_event_id and status='sending';
$$;
create or replace function public.siab_finish_push_event(
  p_event_id uuid,p_success boolean,p_provider_id text)
returns void language sql security invoker set search_path='' as $$
  select siab_private.finish_push_event(p_event_id,p_success,p_provider_id);
$$;

revoke all on function siab_private.event_version(jsonb),siab_private.queue_push_event(),
  siab_private.my_push_identity(),siab_private.claim_push_event(uuid,text,bigint),
  siab_private.finish_push_event(uuid,boolean,text) from public,anon,authenticated;
revoke all on function public.siab_my_push_identity(),public.siab_claim_push_event(uuid,text,bigint),
  public.siab_finish_push_event(uuid,boolean,text) from public,anon,authenticated;
grant execute on function siab_private.my_push_identity(),public.siab_my_push_identity() to authenticated;
grant execute on function siab_private.claim_push_event(uuid,text,bigint),
  siab_private.finish_push_event(uuid,boolean,text),public.siab_claim_push_event(uuid,text,bigint),
  public.siab_finish_push_event(uuid,boolean,text) to service_role;
notify pgrst,'reload schema';
commit;
