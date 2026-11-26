-- Stage 2. Apply only after ops/00_preflight.sql and the deployment guide.
-- No school data is deleted. Existing permissive policies are intersected with
-- restrictive policies; legacy RPCs and materialized views are denied by default.
begin;

do $preflight$
declare item text; expected text[];
begin
  if current_setting('server_version_num')::integer < 150000 then
    raise exception 'PostgreSQL 15+ is required for invoker-security views';
  end if;
  foreach item in array array['siswa','guru','kelas','absensi','surat','pengumuman'] loop
    if to_regclass('public.' || item) is null then
      raise exception 'Missing required table: public.%', item;
    end if;
  end loop;
  foreach item in array array['siswa.id','siswa.nis','siswa.nama','siswa.kelas_id',
    'guru.id','guru.role','guru.nama','guru.no_hp','guru.kelas_diampu',
    'kelas.id','kelas.nama_kelas','absensi.id','absensi.siswa_id','absensi.tanggal',
    'absensi.status','absensi.waktu_masuk','absensi.waktu_pulang',
    'surat.id','surat.siswa_id','surat.tanggal','surat.file_url'] loop
    expected := string_to_array(item, '.');
    if not exists (select 1 from information_schema.columns
      where table_schema='public' and table_name=expected[1] and column_name=expected[2]) then
      raise exception 'Schema mismatch: missing public.%', item;
    end if;
  end loop;
  if exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace join pg_proc p on p.oid=t.tgfoid
    join pg_namespace pn on pn.oid=p.pronamespace
    where n.nspname='public' and c.relname=any(array['siswa','guru','kelas','absensi','surat','pengumuman'])
      and not t.tgisinternal and p.prosecdef and pn.nspname <> 'siab_private'
  ) then
    raise exception 'Review legacy SECURITY DEFINER triggers before migration; see ops/00_preflight.sql';
  end if;
end $preflight$;

create schema if not exists siab_private;
revoke all on schema siab_private from public, anon;
grant usage on schema siab_private to authenticated, service_role;
revoke create on schema public from public, anon, authenticated;

create table if not exists public.siab_wali_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.siab_wali_students (
  wali_id uuid not null references public.siab_wali_accounts(user_id) on delete cascade,
  siswa_id bigint not null references public.siswa(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (wali_id, siswa_id)
);
create index if not exists siab_wali_students_student_idx
  on public.siab_wali_students(siswa_id, wali_id);

create or replace function siab_private.is_admin(actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.guru g where g.id=actor and g.role::text='admin'
    and coalesce(to_jsonb(g)->>'status','aktif') in ('aktif','active'));
$$;
create or replace function siab_private.is_staff(actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.guru g where g.id=actor and g.role::text in ('guru','admin')
    and coalesce(to_jsonb(g)->>'status','aktif') in ('aktif','active'));
$$;
create or replace function siab_private.is_parent(actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select actor=auth.uid()
    and exists(select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) m
      where m->>'method'='otp')
    and exists(select 1 from public.siab_wali_accounts w where w.user_id=actor and w.active);
$$;
create or replace function siab_private.can_teach_class(class_id bigint, actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select siab_private.is_admin(actor) or exists(
    select 1 from public.guru g join public.kelas k on k.id=class_id
    cross join lateral jsonb_each(case when jsonb_typeof(to_jsonb(g)->'kelas_diampu')='object'
      then to_jsonb(g)->'kelas_diampu' else '{}'::jsonb end) grouping
    cross join lateral jsonb_array_elements_text(case when jsonb_typeof(grouping.value)='array'
      then grouping.value else '[]'::jsonb end) assignment(class_name)
    where g.id=actor and g.role::text='guru' and assignment.class_name=k.nama_kelas
      and coalesce(to_jsonb(g)->>'status','aktif') in ('aktif','active')
  );
$$;
create or replace function siab_private.can_read_student(student_id bigint, actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select siab_private.is_admin(actor) or exists(select 1 from public.siswa s where s.id=student_id
    and (siab_private.can_teach_class(s.kelas_id, actor) or (
      siab_private.is_parent(actor) and exists(select 1 from public.siab_wali_students ws
        where ws.wali_id=actor and ws.siswa_id=s.id))));
$$;
create or replace function siab_private.can_write_student(student_id bigint, actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select siab_private.is_admin(actor) or exists(select 1 from public.siswa s
    where s.id=student_id and siab_private.can_teach_class(s.kelas_id,actor));
$$;
create or replace function siab_private.can_read_class(class_id bigint, actor uuid default auth.uid())
returns boolean language sql stable security definer set search_path='' as $$
  select siab_private.can_teach_class(class_id,actor) or (siab_private.is_parent(actor)
    and exists(select 1 from public.siab_wali_students ws join public.siswa s on s.id=ws.siswa_id
      where ws.wali_id=actor and s.kelas_id=class_id));
$$;
create or replace function siab_private.can_submit_letter(student_id bigint)
returns boolean language sql stable security definer set search_path='' as $$
  select siab_private.can_write_student(student_id) or (siab_private.is_parent()
    and exists(select 1 from public.siab_wali_students ws
      where ws.wali_id=auth.uid() and ws.siswa_id=student_id));
$$;
create or replace function siab_private.can_read_announcement(row_data jsonb)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare target text; class_value text; student_value text; selector text; nis_value text;
begin
  if siab_private.is_admin() then return true; end if;
  if not (siab_private.is_staff() or siab_private.is_parent()) then return false; end if;
  target := lower(coalesce(row_data->>'target_role',row_data->>'target',row_data->>'role','all'));
  if target not in ('all','semua','umum','') and not (
    (siab_private.is_parent() and target in ('wali','wali_murid','orangtua')) or
    (siab_private.is_staff() and target='guru')) then return false; end if;
  foreach selector in array array['siswa_id','target_siswa_id','id_siswa','student_id'] loop
    student_value := nullif(row_data->>selector,'');
    if student_value is not null and (student_value !~ '^[0-9]+$'
      or not siab_private.can_read_student(student_value::bigint)) then return false; end if;
  end loop;
  foreach selector in array array['nis','student_nis'] loop
    nis_value := nullif(btrim(row_data->>selector),'');
    if nis_value is not null and not exists(select 1 from public.siswa s
      where s.nis=nis_value and siab_private.can_read_student(s.id)) then return false; end if;
  end loop;
  if nullif(row_data->>'target_user_id','') is not null
    and row_data->>'target_user_id'<>auth.uid()::text then return false; end if;
  class_value := coalesce(nullif(row_data->>'kelas_id',''),nullif(row_data->>'id_kelas',''));
  if class_value is not null then
    if class_value !~ '^[0-9]+$' then return false; end if;
    return siab_private.can_read_class(class_value::bigint);
  end if;
  class_value := coalesce(nullif(row_data->>'nama_kelas',''),nullif(row_data->>'kelas',''));
  if class_value is not null and lower(class_value) not in ('all','semua','umum') then
    return exists(select 1 from public.kelas k where k.nama_kelas=class_value
      and siab_private.can_read_class(k.id));
  end if;
  return true;
end $$;

-- Dynamic guards use row JSON so optional legacy columns need not be invented.
create or replace function siab_private.protect_staff_scope()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is not null and not siab_private.is_admin() and (
    (to_jsonb(new)->'id') is distinct from (to_jsonb(old)->'id') or
    (to_jsonb(new)->'role') is distinct from (to_jsonb(old)->'role') or
    (to_jsonb(new)->'kelas_diampu') is distinct from (to_jsonb(old)->'kelas_diampu') or
    (to_jsonb(new)->'status') is distinct from (to_jsonb(old)->'status')) then
    raise exception using errcode='42501', message='Staff authorization fields are admin managed';
  end if;
  return new;
end $$;
drop trigger if exists siab_protect_staff_scope on public.guru;
create trigger siab_protect_staff_scope before update on public.guru
  for each row execute function siab_private.protect_staff_scope();

-- Restrictive policies remain effective even if old permissive policies allow ALL.
do $policies$
declare t text; operation text; read_guard text; write_guard text; guard text;
begin
  foreach t in array array['siswa','guru','kelas','absensi','surat','pengumuman',
    'siab_wali_accounts','siab_wali_students'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from public, anon, authenticated',t);
    -- Table REVOKE does not remove old column ACLs.
    for guard in select a.attname from pg_attribute a
      where a.attrelid=('public.'||quote_ident(t))::regclass
        and a.attnum>0 and not a.attisdropped and a.attacl is not null loop
      execute format('revoke all (%I) on public.%I from public,anon,authenticated',guard,t);
    end loop;
    execute format('grant select,insert,update,delete on public.%I to authenticated',t);
    case t
      when 'siswa' then read_guard := 'siab_private.can_read_student(id)';
      when 'guru' then read_guard := '(id=auth.uid() or siab_private.is_admin())';
      when 'kelas' then read_guard := 'siab_private.can_read_class(id)';
      when 'absensi' then read_guard := 'siab_private.can_read_student(siswa_id)';
      when 'surat' then read_guard := 'siab_private.can_read_student(siswa_id)';
      when 'pengumuman' then read_guard := 'siab_private.can_read_announcement(to_jsonb(pengumuman))';
      when 'siab_wali_accounts' then read_guard := '(user_id=auth.uid() or siab_private.is_admin())';
      when 'siab_wali_students' then read_guard := '((wali_id=auth.uid() and siab_private.is_parent()) or siab_private.is_admin())';
    end case;
    foreach operation in array array['select','insert','update','delete'] loop
      write_guard := 'siab_private.is_admin()';
      if t='guru' and operation='update' then write_guard := read_guard; end if;
      if t='absensi' and operation in ('insert','update') then
        write_guard := 'siab_private.can_write_student(siswa_id)';
      end if;
      if t='surat' then
        if operation='insert' then
          write_guard := '(siab_private.can_write_student(siswa_id) or (siab_private.can_submit_letter(siswa_id)'
            || ' and coalesce(to_jsonb(surat)->>''status'',''menunggu'')=''menunggu'''
            || ' and nullif(to_jsonb(surat)->>''catatan_guru'','''') is null))';
        else
          write_guard := 'siab_private.can_write_student(siswa_id)';
        end if;
      end if;
      guard := case when operation='select' then read_guard else write_guard end;
      execute format('drop policy if exists %I on public.%I','siab_guard_'||operation,t);
      execute format('drop policy if exists %I on public.%I','siab_allow_'||operation,t);
      if operation='insert' then
        execute format('create policy %I on public.%I as restrictive for insert to authenticated with check (%s)',
          'siab_guard_'||operation,t,guard);
        execute format('create policy %I on public.%I for insert to authenticated with check (%s)',
          'siab_allow_'||operation,t,guard);
      elsif operation='update' then
        execute format('create policy %I on public.%I as restrictive for update to authenticated using (%s) with check (%s)',
          'siab_guard_'||operation,t,guard,guard);
        execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)',
          'siab_allow_'||operation,t,guard,guard);
      else
        execute format('create policy %I on public.%I as restrictive for %s to authenticated using (%s)',
          'siab_guard_'||operation,t,operation,guard);
        execute format('create policy %I on public.%I for %s to authenticated using (%s)',
          'siab_allow_'||operation,t,operation,guard);
      end if;
    end loop;
  end loop;
end $policies$;

-- INSERT defaults need nextval(), but callers must not reset ID sequences.
do $sequences$
declare t text; sequence_name text;
begin
  foreach t in array array['siswa','guru','kelas','absensi','surat','pengumuman'] loop
    sequence_name := pg_get_serial_sequence('public.'||quote_ident(t),'id');
    if sequence_name is not null then
      execute format('revoke all on sequence %s from public,anon,authenticated',sequence_name);
      execute format('grant usage on sequence %s to authenticated',sequence_name);
    end if;
  end loop;
end $sequences$;

-- Legacy SECURITY DEFINER RPCs must not bypass the new table policies.
-- Only the new, versioned RPCs below are granted to clients.
do $legacy$
declare obj record;
begin
  for obj in select p.oid::regprocedure signature from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
      and p.prokind='f' and not exists(select 1 from pg_depend d
        where d.objid=p.oid and d.deptype='e') loop
    execute format('revoke all on function %s from public,anon,authenticated',obj.signature);
    execute format('grant execute on function %s to service_role',obj.signature);
  end loop;
  for obj in select c.relname,c.relkind from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('v','m') loop
    execute format('revoke all on public.%I from public,anon',obj.relname);
    if obj.relkind='v' then
      execute format('alter view public.%I set (security_invoker=true,security_barrier=true)',obj.relname);
    else
      execute format('revoke all on public.%I from authenticated',obj.relname);
    end if;
  end loop;
end $legacy$;
alter default privileges in schema public revoke execute on functions from public,anon,authenticated;

create or replace function siab_private.my_children()
returns setof jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not siab_private.is_parent() then
    raise exception using errcode='42501', message='Verified enrolled parent required';
  end if;
  return query select jsonb_build_object('id',s.id,'nis',s.nis,'nama',s.nama,
    'kelas_id',s.kelas_id,'nama_kelas',k.nama_kelas,
    'wali_kelas_nama',contact.nama,'wali_kelas_no_hp',contact.no_hp)
    from public.siab_wali_students ws join public.siswa s on s.id=ws.siswa_id
    left join public.kelas k on k.id=s.kelas_id
    left join lateral(select g.nama,g.no_hp from public.guru g
      where g.id::text=coalesce(to_jsonb(k)->>'wali_kelas',to_jsonb(k)->>'wali_kelas_id')
        or (g.nama=to_jsonb(k)->>'wali_kelas' and siab_private.can_teach_class(k.id,g.id))
      order by g.id limit 1) contact on true
    where ws.wali_id=auth.uid() order by s.nama,s.id;
end $$;
create or replace function public.siab_my_children()
returns setof jsonb language sql stable security invoker set search_path='' as $$
  select * from siab_private.my_children();
$$;

create or replace function public.siab_guru_dashboard(p_guru_id uuid)
returns setof jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('nama_kelas',k.nama_kelas,'total_siswa',count(s.id),
    'hadir',count(s.id) filter(where a.status::text='hadir'),
    'terlambat',count(s.id) filter(where a.status::text='terlambat'),
    'pulang',count(s.id) filter(where a.status::text='pulang'),
    'sakit',count(s.id) filter(where a.status::text='sakit'),
    'izin',count(s.id) filter(where a.status::text='izin'),
    'alfa',count(s.id) filter(where a.status::text='alfa'))
  from public.kelas k left join public.siswa s on s.kelas_id=k.id
  left join public.absensi a on a.siswa_id=s.id
    and a.tanggal::date=(now() at time zone 'Asia/Jakarta')::date
  where p_guru_id=auth.uid() and siab_private.is_staff()
    and siab_private.can_teach_class(k.id) group by k.id,k.nama_kelas order by k.nama_kelas;
$$;
create or replace function public.siab_kelas_today(p_nama_kelas text)
returns setof jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('id',s.id,'no',row_number() over(order by s.nama,s.id),
    'nama',s.nama,'status_absensi',a.status,'jam_masuk',a.waktu_masuk,
    'jam_pulang',a.waktu_pulang,'file_url',letter.file_url,
    'keterangan',to_jsonb(a)->>'keterangan')
  from public.siswa s join public.kelas k on k.id=s.kelas_id
  left join public.absensi a on a.siswa_id=s.id
    and a.tanggal::date=(now() at time zone 'Asia/Jakarta')::date
  left join lateral(select su.file_url from public.surat su where su.siswa_id=s.id
    and su.tanggal::date=(now() at time zone 'Asia/Jakarta')::date order by su.id desc limit 1) letter on true
  where k.nama_kelas=p_nama_kelas and siab_private.is_staff()
    and siab_private.can_teach_class(k.id) order by s.nama,s.id;
$$;

-- Paths are independently bound to students. A forged surat.file_url cannot
-- make another student's object readable through a newly inserted letter.
create or replace function siab_private.document_student(object_name text)
returns bigint language plpgsql immutable set search_path='' as $$
declare id_text text;
begin
  if object_name ~ '(^|/)\.{1,2}(/|$)' or position(chr(92) in object_name)>0 then return null; end if;
  id_text := coalesce(substring(object_name from '^([0-9]+)/[A-Za-z0-9_.-]+$'),
    substring(object_name from '^pengajuan/surat_([0-9]+)_[A-Za-z0-9_.-]+$'),
    substring(object_name from '^absensi/([0-9]+)_[A-Za-z0-9_.-]+$'));
  if id_text is null or length(id_text)>18 then return null; end if;
  return id_text::bigint;
end $$;
create or replace function siab_private.protect_letter_reference()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' then
    if new.file_url is not distinct from old.file_url and new.siswa_id=old.siswa_id then return new; end if;
  end if;
  if nullif(new.file_url,'') is not null and
    siab_private.document_student(new.file_url) is distinct from new.siswa_id then
    raise exception using errcode='42501',message='Document path does not belong to the student';
  end if;
  return new;
end $$;
drop trigger if exists siab_protect_letter_reference on public.surat;
create trigger siab_protect_letter_reference before insert or update on public.surat
  for each row execute function siab_private.protect_letter_reference();
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('surat_keterangan','surat_keterangan',false,5242880,array['image/jpeg','image/png'])
  on conflict(id) do update set public=false,file_size_limit=5242880,
    allowed_mime_types=array['image/jpeg','image/png'];
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('avatars','avatars',true,5242880,array['image/jpeg','image/png'])
  on conflict(id) do nothing;

do $storage$
declare operation text; guard text;
begin
  foreach operation in array array['select','insert','update','delete'] loop
    guard := case when operation='select' then
      'siab_private.can_read_student(siab_private.document_student(name))'
      when operation='insert' then 'siab_private.can_submit_letter(siab_private.document_student(name))'
      else 'siab_private.can_write_student(siab_private.document_student(name))' end;
    -- Add a restrictive guard for everyone, including anon and legacy PUBLIC policies.
    guard := '(bucket_id<>''surat_keterangan'' or (auth.uid() is not null and ('||guard||')))';
    if operation<>'select' then
      guard := guard || ' and (bucket_id<>''avatars'' or (auth.uid() is not null'
        || ' and siab_private.is_staff() and (storage.foldername(name))[1]=auth.uid()::text))';
    end if;
    execute format('drop policy if exists %I on storage.objects','siab_document_guard_'||operation);
    if operation='insert' then
      execute format('create policy %I on storage.objects as restrictive for insert to public with check (%s)',
        'siab_document_guard_'||operation,guard);
    elsif operation='update' then
      execute format('create policy %I on storage.objects as restrictive for update to public using (%s) with check (%s)',
        'siab_document_guard_'||operation,guard,guard);
    else
      execute format('create policy %I on storage.objects as restrictive for %s to public using (%s)',
        'siab_document_guard_'||operation,operation,guard);
    end if;
  end loop;
end $storage$;
drop policy if exists siab_document_read on storage.objects;
create policy siab_document_read on storage.objects for select to authenticated
  using(bucket_id='surat_keterangan' and siab_private.can_read_student(siab_private.document_student(name)));
drop policy if exists siab_document_upload on storage.objects;
create policy siab_document_upload on storage.objects for insert to authenticated
  with check(bucket_id='surat_keterangan' and siab_private.can_submit_letter(siab_private.document_student(name)));
-- New uploads never overwrite/delete documents. Old broad storage policies are
-- still bounded by the restrictive guards, including legacy file-name support.
drop policy if exists siab_avatar_upload on storage.objects;
create policy siab_avatar_upload on storage.objects for insert to authenticated
  with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text and siab_private.is_staff());

revoke all on all functions in schema siab_private from public,anon,authenticated;
grant execute on function siab_private.is_admin(uuid),siab_private.is_staff(uuid),
  siab_private.is_parent(uuid),siab_private.can_teach_class(bigint,uuid),
  siab_private.can_read_student(bigint,uuid),siab_private.can_write_student(bigint,uuid),
  siab_private.can_read_class(bigint,uuid),siab_private.can_submit_letter(bigint),
  siab_private.can_read_announcement(jsonb),siab_private.document_student(text),
  siab_private.my_children() to authenticated;
revoke all on function public.siab_my_children(),public.siab_guru_dashboard(uuid),
  public.siab_kelas_today(text) from public,anon;
grant execute on function public.siab_my_children(),public.siab_guru_dashboard(uuid),
  public.siab_kelas_today(text) to authenticated;
notify pgrst,'reload schema';
commit;
