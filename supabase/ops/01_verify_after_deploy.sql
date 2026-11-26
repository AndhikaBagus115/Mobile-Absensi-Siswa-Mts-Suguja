-- READ ONLY metadata verification after applying BOTH migrations.
select c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in (
  'siswa','guru','kelas','absensi','surat','pengumuman','siab_wali_accounts','siab_wali_students');

select id,public from storage.buckets where id='surat_keterangan'; -- must be false

select t.table_name,
  has_table_privilege('anon','public.'||quote_ident(t.table_name),'SELECT') anon_table_select,
  has_any_column_privilege('anon','public.'||quote_ident(t.table_name),'SELECT') anon_column_select
from information_schema.tables t where t.table_schema='public'
  and t.table_name in ('siswa','guru','kelas','absensi','surat','pengumuman'); -- all false

select p.oid::regprocedure function_signature,
  has_function_privilege('anon',p.oid,'EXECUTE') anon_execute,
  has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname like 'siab_%' order by p.proname;
-- Authenticated: only siab_my_children, siab_my_push_identity,
-- siab_guru_dashboard and siab_kelas_today. Claim/finish: service_role only.
