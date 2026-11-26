-- READ ONLY. Run in the SQL editor before either migration.
-- Outputs schema/ACL metadata only, never school rows or function source/secrets.
select current_setting('server_version') postgres_version;

select c.table_name,c.column_name,c.data_type,c.udt_name,c.is_nullable
from information_schema.columns c where c.table_schema='public'
  and c.table_name in ('siswa','guru','kelas','absensi','surat','pengumuman')
order by c.table_name,c.ordinal_position;

select n.nspname schema_name,c.relname object_name,c.relkind,c.relrowsecurity,
  pg_get_userbyid(c.relowner) owner,c.reloptions
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('r','v','m','p')
order by c.relname;

select schemaname,tablename,policyname,roles,cmd,permissive,
  qual in ('true','(true)') unconditional_using,
  with_check in ('true','(true)') unconditional_check
from pg_policies where schemaname in ('public','storage')
order by schemaname,tablename,policyname;

select table_schema,table_name,grantee,privilege_type
from information_schema.table_privileges
where table_schema in ('public','storage')
  and grantee in ('PUBLIC','anon','authenticated','service_role')
order by table_schema,table_name,grantee,privilege_type;

select table_schema,table_name,column_name,grantee,privilege_type
from information_schema.column_privileges
where table_schema='public' and grantee in ('PUBLIC','anon','authenticated')
order by table_name,column_name,grantee;

select p.oid::regprocedure function_signature,p.prosecdef security_definer,
  p.proconfig settings,has_function_privilege('anon',p.oid,'EXECUTE') anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_execute,
  encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') source_hash
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prokind='f' order by p.proname;

select c.relname table_name,t.tgname trigger_name,p.oid::regprocedure function_signature,
  p.prosecdef security_definer,
  pg_get_functiondef(p.oid) ~* '(onesignal|net[.]http|http_post|send.push)' network_code_detected,
  encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') source_hash
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace join pg_proc p on p.oid=t.tgfoid
where n.nspname='public' and not t.tgisinternal order by c.relname,t.tgname;

select id,public,file_size_limit,allowed_mime_types from storage.buckets
where id in ('surat_keterangan','avatars');

-- Check FK/unique constraints without displaying rows or their values.
select conrelid::regclass table_name,conname,contype,convalidated
from pg_constraint where conrelid in (
  'public.siswa'::regclass,'public.guru'::regclass,'public.kelas'::regclass,
  'public.absensi'::regclass,'public.surat'::regclass)
order by conrelid::regclass::text,conname;
