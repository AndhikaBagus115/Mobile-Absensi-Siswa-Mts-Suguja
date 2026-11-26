import { createSendPushHandler, type PushConfig } from "../functions/send-push/handler.ts";

function check(condition: unknown, message = "Assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}
const userId = "11111111-1111-4111-8111-111111111111";
const eventId = "22222222-2222-4222-8222-222222222222";
const providerId = "33333333-3333-4333-8333-333333333333";
const config: PushConfig = { projectUrl: "https://project.invalid", anonKey: "public-key",
  serviceRoleKey: "private-service-sentinel", appId: "test-app", restKey: "os_v2_private-sentinel" };

function harness(options: {
  authDenied?: boolean; roleDenied?: boolean; rateLimited?: boolean;
  jobStatus?: string; providerBody?: unknown; providerStatus?: number;
} = {}) {
  const requests: { url: string; body: Record<string, unknown>; headers: Headers }[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    requests.push({ url, body, headers: new Headers(init?.headers) });
    const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
    if (url.endsWith("/auth/v1/user")) {
      return options.authDenied ? response({ msg: "private-auth-error" }, 401) : response({ id: userId });
    }
    if (url.endsWith("/siab_claim_push_event")) {
      if (options.roleDenied) return response({ code: "42501", message: "denied" }, 403);
      if (options.rateLimited) return response({ code: "P0001", message: "RATE_LIMITED" }, 400);
      return response({ status: options.jobStatus ?? "ready", event_id: eventId,
        siswa_id: 9001, recipient_external_ids: ["a".repeat(64)] });
    }
    if (url.endsWith("/siab_finish_push_event")) return response(null);
    if (url === "https://api.onesignal.com/notifications") {
      return response(options.providerBody ?? { id: providerId }, options.providerStatus ?? 200);
    }
    throw new Error("Unexpected mocked endpoint");
  };
  return { handler: createSendPushHandler(config, fetcher), requests };
}
const request = (body: unknown = { event_type: "attendance", record_id: 12 }, headers = {}) =>
  new Request("https://function.invalid/send-push", { method: "POST",
    headers: { authorization: "Bearer synthetic.header.signature", "content-type": "application/json", ...headers },
    body: JSON.stringify(body) });

Deno.test("anonymous push is rejected before any backend or provider request", async () => {
  const { handler, requests } = harness();
  const result = await handler(new Request("https://function.invalid", { method: "POST", body: "{}" }));
  check(result.status === 401);
  check(requests.length === 0);
});
Deno.test("only POST and preflight are accepted", async () => {
  const { handler, requests } = harness();
  check((await handler(new Request("https://function.invalid"))).status === 405);
  check((await handler(new Request("https://function.invalid", { method: "OPTIONS" }))).status === 204);
  check(requests.length === 0);
});
Deno.test("tampered audiences, content, actor IDs and malformed identities are rejected", async (t) => {
  for (const body of [
    { event_type: "attendance", record_id: 12, included_segments: ["All"] },
    { event_type: "attendance", record_id: 12, headings: { en: "forged" } },
    { event_type: "attendance", record_id: 12, p_actor_id: userId },
    { event_type: "broadcast", record_id: 12 },
    { event_type: ["attendance"], record_id: 12 },
    { event_type: "attendance", record_id: -1 },
    { event_type: "attendance", record_id: "12" },
    { event_type: "attendance", record_id: Number.MAX_SAFE_INTEGER + 1 },
  ]) {
    await t.step(JSON.stringify(body), async () => {
      const { handler, requests } = harness();
      check((await handler(request(body))).status === 400);
      check(requests.length === 0);
    });
  }
});
Deno.test("non-JSON and oversized bodies are rejected without provider calls", async () => {
  const { handler, requests } = harness();
  check((await handler(request({}, { "content-type": "text/plain" }))).status === 415);
  check((await handler(request({ padding: "x".repeat(2000) }))).status === 413);
  check(requests.length === 0);
});
Deno.test("forged or expired sessions stop before privileged RPC", async () => {
  const { handler, requests } = harness({ authDenied: true });
  check((await handler(request())).status === 401);
  check(requests.length === 1);
});
Deno.test("parent and out-of-class denials never reach OneSignal", async () => {
  const { handler, requests } = harness({ roleDenied: true });
  check((await handler(request())).status === 403);
  check(requests.every((entry) => !entry.url.includes("onesignal.com")));
});
Deno.test("rate limits reject before the provider", async () => {
  const { handler, requests } = harness({ rateLimited: true });
  check((await handler(request())).status === 429);
  check(requests.every((entry) => !entry.url.includes("onesignal.com")));
});
Deno.test("committed event and server recipient IDs determine the push", async () => {
  const { handler, requests } = harness();
  const response = await handler(request({ event_type: "letter_decision", record_id: 12 }));
  check(response.status === 200);
  const claim = requests.find((entry) => entry.url.endsWith("/siab_claim_push_event"))!;
  check(claim.body.p_actor_id === userId);
  check(claim.headers.get("authorization") === `Bearer ${config.serviceRoleKey}`);
  const provider = requests.find((entry) => entry.url.includes("onesignal.com"))!;
  check(provider.body.idempotency_key === eventId);
  check(JSON.stringify(provider.body.include_aliases) === JSON.stringify({ external_id: ["a".repeat(64)] }));
  check(!("filters" in provider.body) && !("included_segments" in provider.body));
  check(!JSON.stringify(provider.body).includes(userId));
  check(!JSON.stringify(provider.body).includes("nama_siswa"));
  const result = await response.text();
  check(!result.includes("sentinel") && !result.includes("a".repeat(64)));
});
Deno.test("duplicate, in-progress and unsubscribed events never broadcast", async (t) => {
  for (const status of ["already_sent", "in_progress", "no_recipients", "no_event"]) {
    await t.step(status, async () => {
      const { handler, requests } = harness({ jobStatus: status });
      const result = await handler(request());
      check(result.status === (status === "already_sent" ? 200 : status === "no_event" ? 409 : 202));
      check(requests.every((entry) => !entry.url.includes("onesignal.com")));
    });
  }
});
Deno.test("HTTP 200 with an empty ID or zero recipients is not success", async (t) => {
  for (const body of [{ id: "", recipients: 0 }, { id: providerId, recipients: 0 },
    { id: providerId, errors: ["private-provider-sentinel"] }]) {
    await t.step(JSON.stringify(body), async () => {
      const { handler, requests } = harness({ providerBody: body });
      const result = await handler(request());
      check(result.status === 502);
      check(!((await result.text()).includes("private-provider-sentinel")));
      const finish = requests.find((entry) => entry.url.endsWith("/siab_finish_push_event"))!;
      check(finish.body.p_success === false);
    });
  }
});
