import { PGlite } from "@electric-sql/pglite";

const ids = {
  teacherA: "11111111-1111-4111-8111-111111111111",
  teacherB: "22222222-2222-4222-8222-222222222222",
  admin: "33333333-3333-4333-8333-333333333333",
  parentA: "44444444-4444-4444-8444-444444444444",
  parentB: "55555555-5555-4555-8555-555555555555",
  outsider: "66666666-6666-4666-8666-666666666666",
};
function check(condition: unknown, message = "Database security assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}
const file = (name: string) => Deno.readTextFile(new URL(name, import.meta.url));

Deno.test("stage 2 database boundaries on a real PostgreSQL WASM engine", async (t) => {
  const db = new PGlite();
  await db.waitReady;
  const role = async (actor?: string, method = "otp", dbRole = "authenticated") => {
    await db.exec(`set local role ${actor ? dbRole : dbRole === "service_role" ? "service_role" : "anon"}`);
    await db.query("select set_config('request.jwt.claims',$1,true)", [JSON.stringify(
      actor ? { sub: actor, role: dbRole, amr: [{ method }] } : { role: dbRole },
    )]);
  };
  const isolated = async (fn: () => Promise<void>) => {
    await db.exec("begin");
    try { await fn(); } finally { await db.exec("rollback"); }
  };
  const count = async (query: string) => {
    const result = await db.query<{ count: number }>(`select count(*)::integer count from (${query}) q`);
    return result.rows[0].count;
  };
  const denied = async (query: string, expectedCode = "42501") => {
    await db.exec("savepoint denied_probe");
    let rejected = false;
    try { await db.exec(query); } catch (error) {
      rejected = (error as { code?: string }).code === expectedCode;
    } finally { await db.exec("rollback to denied_probe; release denied_probe"); }
    check(rejected, "Expected SQL permission denial");
  };
  try {
    await db.exec(await file("./fixture.sql"));
    await t.step("baseline fixture reproduces anonymous access and legacy RPC bypass", () => isolated(async () => {
      await role();
      check(await count("select * from public.siswa") === 3);
      check(await count("select * from public.legacy_dump_students()") === 3);
    }));
    if (Deno.env.get("SIAB_TEST_UNPATCHED") !== "1") {
      await db.exec(await file("../migrations/202611260001_access_and_private_storage.sql"));
      await db.exec(await file("../migrations/202611260002_authorized_push_events.sql"));
      await db.exec(`insert into public.siab_wali_accounts(user_id) values('${ids.parentA}'),('${ids.parentB}');
        insert into public.siab_wali_students(wali_id,siswa_id) values('${ids.parentA}',9001),('${ids.parentB}',9002)`);
    }
    await t.step("anonymous callers cannot read private tables, columns, views or legacy RPCs", () => isolated(async () => {
      await role();
      for (const table of ["siswa", "guru", "kelas", "absensi", "surat", "pengumuman"]) {
        await denied(`select * from public.${table}`);
      }
      await denied("select nama from public.siswa");
      await denied("select * from public.legacy_dump_students()");
      await denied("select * from public.legacy_student_view");
    }));
    // The unpatched fixture is used only to prove the denial assertion goes red.
    if (Deno.env.get("SIAB_TEST_UNPATCHED") === "1") return;
    await t.step("parent A cannot read parent B's child even in the same class", () => isolated(async () => {
      await role(ids.parentA);
      check(await count("select * from public.siswa") === 1);
      check(await count("select * from public.siswa where id=9002") === 0);
      check(await count("select * from public.absensi where siswa_id=9002") === 0);
      check(await count("select * from public.surat where siswa_id=9002") === 0);
      check(await count("select * from public.siab_my_children()") === 1);
      const child = await db.query<{ child: { id: number } }>("select public.siab_my_children() child");
      check(child.rows[0].child.id === 9001);
    }));
    await t.step("parent membership requires an OTP session, not only a password", () => isolated(async () => {
      await role(ids.parentA, "password");
      check(await count("select * from public.siswa") === 0);
      await denied("select * from public.siab_my_children()");
      await denied("select public.siab_my_push_identity()");
    }));
    await t.step("unregistered and inactive parents have no child access", () => isolated(async () => {
      await db.exec(`update public.siab_wali_accounts set active=false where user_id='${ids.parentA}'`);
      await role(ids.parentA);
      check(await count("select * from public.siswa") === 0);
      await denied("select * from public.siab_my_children()");
      await role(ids.outsider);
      check(await count("select * from public.siswa") === 0);
      await denied("select * from public.siab_my_children()");
    }));
    await t.step("teachers only see assigned classes and cannot spoof the dashboard actor", () => isolated(async () => {
      await role(ids.teacherA, "password");
      check(await count("select * from public.siswa") === 2);
      check(await count("select * from public.siswa where kelas_id=2") === 0);
      check(await count("select * from public.siab_kelas_today('9B')") === 0);
      check(await count(`select * from public.siab_guru_dashboard('${ids.teacherB}')`) === 0);
      check(await count(`select * from public.siab_guru_dashboard('${ids.teacherA}')`) === 1);
      check(await count("select * from public.siab_kelas_today('9A')") === 2);
    }));
    await t.step("self-service profile updates cannot grant admin or another class", () => isolated(async () => {
      await role(ids.teacherA, "password");
      await denied(`update public.guru set role='admin' where id='${ids.teacherA}'`);
      await denied(`update public.guru set kelas_diampu='{"IX":["9B"]}' where id='${ids.teacherA}'`);
      await db.exec(`update public.guru set nama='Guru Uji Diperbarui' where id='${ids.teacherA}'`);
      check(await count("select * from public.siswa where kelas_id=2") === 0);
    }));
    await t.step("parents cannot assign children, change attendance or approve letters", () => isolated(async () => {
      await role(ids.parentA);
      await denied(`insert into public.siab_wali_students values('${ids.parentA}',9002,now())`);
      await denied("insert into public.absensi(id,siswa_id,tanggal,status) values(90,9001,current_date,'hadir')");
      await denied("insert into public.surat(id,siswa_id,tanggal,status) values(90,9001,current_date,'disetujui')");
      const updated = await db.query("update public.surat set status='disetujui' where id=1 returning id");
      check(updated.rows.length === 0);
    }));
    await t.step("parents can submit their own pending letter with a generated ID but not forge another file", () => isolated(async () => {
      await role(ids.parentA);
      const result = await db.query("insert into public.surat(siswa_id,tanggal,file_url,status) values(9001,current_date,'9001/new.jpg','menunggu') returning id");
      check(result.rows.length === 1);
      await denied("insert into public.surat(siswa_id,tanggal,file_url,status) values(9001,current_date,'9002/bukti.jpg','menunggu')");
    }));
    await t.step("private storage follows the object student, including old file layouts", () => isolated(async () => {
      await role(ids.parentA);
      check(await count("select * from storage.objects") === 2);
      check(await count("select * from storage.objects where name='9002/bukti.jpg'") === 0);
      await denied("insert into storage.objects(bucket_id,name) values('surat_keterangan','9002/forged.jpg')");
      await db.exec("insert into storage.objects(bucket_id,name) values('surat_keterangan','9001/owned.jpg')");
      await denied("insert into storage.objects(bucket_id,name) values('avatars','public-medical-file.jpg')");
    }));
    await t.step("legacy views obey RLS and materialized data is not exposed", () => isolated(async () => {
      await role(ids.parentA);
      check(await count("select * from public.legacy_student_view") === 1);
      await denied("select * from public.legacy_student_snapshot");
    }));
    await t.step("announcement role and class boundaries are enforced on the server", () => isolated(async () => {
      await role(ids.parentA);
      check(await count("select * from public.pengumuman") === 2);
      check(await count("select * from public.pengumuman where id in (3,4,5)") === 0);
    }));
    await t.step("legacy announcement target aliases do not leak another child's message", () => isolated(async () => {
      await role(ids.parentA);
      for (const target of [{ target_siswa_id: 9002 }, { id_siswa: 9002 },
        { student_id: 9002 }, { nis: "UJI-B" }, { student_nis: "UJI-B" }, { id_kelas: 2 }]) {
        const result = await db.query<{ allowed: boolean }>(
          "select siab_private.can_read_announcement($1::jsonb) allowed", [JSON.stringify(target)]);
        check(result.rows[0].allowed === false);
      }
    }));
    await t.step("authenticated clients cannot claim service jobs or select recipient mappings", () => isolated(async () => {
      await role(ids.parentA);
      await denied(`select public.siab_claim_push_event('${ids.admin}','attendance',1)`);
      await denied("select * from siab_private.push_identities");
      const own = await db.query<{ identity: string }>("select public.siab_my_push_identity() identity");
      check(/^[a-f0-9]{64}$/.test(own.rows[0].identity));
      check(!own.rows[0].identity.includes(ids.parentA));
    }));
    await t.step("service calls still enforce staff class permissions and deny parents", () => isolated(async () => {
      await role(undefined, "password", "service_role");
      await denied(`select public.siab_claim_push_event('${ids.teacherA}','attendance',3)`);
      await denied(`select public.siab_claim_push_event('${ids.parentA}','attendance',1)`);
    }));
    await t.step("committed events lease once, retry with the same id and deduplicate success", () => isolated(async () => {
      await role(ids.parentA);
      const parentIdentity = await db.query<{ identity: string }>("select public.siab_my_push_identity() identity");
      await role(ids.parentB);
      await db.query("select public.siab_my_push_identity()");
      await role(ids.teacherA, "password");
      await db.exec("update public.absensi set waktu_pulang='14:00',status='pulang' where id=1");
      await role(undefined, "password", "service_role");
      const claim = () => db.query<{ job: Record<string, unknown> }>(
        `select public.siab_claim_push_event('${ids.teacherA}','attendance',1) job`);
      const first = (await claim()).rows[0].job;
      check(first.status === "ready");
      check((first.recipient_external_ids as string[]).length === 1);
      check((first.recipient_external_ids as string[])[0] === parentIdentity.rows[0].identity);
      check((await claim()).rows[0].job.status === "in_progress");
      await db.query("select public.siab_finish_push_event($1,false,null)", [first.event_id]);
      const retry = (await claim()).rows[0].job;
      check(retry.event_id === first.event_id);
      await db.query("select public.siab_finish_push_event($1,true,$2)", [first.event_id, "test-provider-id"]);
      check((await claim()).rows[0].job.status === "already_sent");
    }));
    await t.step("historical records without a new committed event cannot send notifications", () => isolated(async () => {
      await role(undefined, "password", "service_role");
      const result = await db.query<{ job: { status: string } }>(
        `select public.siab_claim_push_event('${ids.teacherA}','attendance',1) job`);
      check(result.rows[0].job.status === "no_event");
    }));
    await t.step("the service sender rate limit is enforced inside PostgreSQL", () => isolated(async () => {
      await db.exec(`insert into siab_private.push_rate_limits(actor_id,minute,requests)
        select '${ids.teacherA}',date_trunc('minute',clock_timestamp())+offset_value,120
        from (values(interval '0 minutes'),(interval '1 minute')) buckets(offset_value)`);
      await role(undefined,"password","service_role");
      await denied(`select public.siab_claim_push_event('${ids.teacherA}','attendance',1)`,"P0001");
    }));
    await t.step("admin remains authorized to the school tables", () => isolated(async () => {
      await role(ids.admin, "password");
      check(await count("select * from public.siswa") === 3);
      check(await count("select * from public.guru") === 3);
    }));
    const bucket = await db.query<{ public: boolean }>("select public from storage.buckets where id='surat_keterangan'");
    check(bucket.rows[0].public === false);
  } finally { await db.close(); }
});
