export interface PushConfig {
  projectUrl: string;
  anonKey: string;
  serviceRoleKey: string;
  appId: string;
  restKey: string;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const json = (status: number, body: Record<string, unknown>) => new Response(
  JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } },
);
const object = (value: unknown): Record<string, unknown> | null =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;

class RequestFailure extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}

async function boundedJson(req: Request): Promise<Record<string, unknown>> {
  const limit = 1024;
  if (Number(req.headers.get("content-length")) > limit) {
    throw new RequestFailure(413, "payload_too_large");
  }
  const reader = req.body?.getReader();
  if (!reader) throw new RequestFailure(400, "invalid_payload");
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  while (true) {
    const next = await reader.read();
    if (next.done) break;
    bytes += next.value.byteLength;
    if (bytes > limit) {
      await reader.cancel();
      throw new RequestFailure(413, "payload_too_large");
    }
    chunks.push(next.value);
  }
  const merged = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) { merged.set(chunk, offset); offset += chunk.length; }
  try {
    const value = object(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(merged)));
    if (!value) throw new Error();
    return value;
  } catch { throw new RequestFailure(400, "invalid_payload"); }
}

export function createSendPushHandler(config: PushConfig, fetcher: typeof fetch = fetch) {
  const rpc = async (name: string, body: Record<string, unknown>) => {
    const response = await fetcher(`${config.projectUrl}/rest/v1/rpc/${name}`, {
      method: "POST", signal: AbortSignal.timeout(7000),
      headers: { apikey: config.serviceRoleKey,
        Authorization: `Bearer ${config.serviceRoleKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const error = object(data);
      if (error?.message === "RATE_LIMITED") throw new RequestFailure(429, "rate_limited");
      if (error?.code === "42501") throw new RequestFailure(403, "not_authorized");
      throw new RequestFailure(503, "event_service_unavailable");
    }
    return data;
  };
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
    const authorization = req.headers.get("authorization") ?? "";
    if (authorization.length > 8192 || !/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/i.test(authorization)) {
      return json(401, { error: "authentication_required" });
    }
    let claimedId: string | null = null;
    try {
      if (!Object.values(config).every((value) => value.length > 0)) {
        throw new RequestFailure(503, "service_unavailable");
      }
      if (req.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
        throw new RequestFailure(415, "json_required");
      }
      const input = await boundedJson(req);
      if (Object.keys(input).sort().join(",") !== "event_type,record_id" ||
          typeof input.event_type !== "string" ||
          !["attendance", "letter_decision"].includes(input.event_type) ||
          !Number.isSafeInteger(input.record_id) || Number(input.record_id) <= 0) {
        throw new RequestFailure(400, "invalid_payload");
      }
      const auth = await fetcher(`${config.projectUrl}/auth/v1/user`, {
        headers: { apikey: config.anonKey, Authorization: authorization },
        signal: AbortSignal.timeout(5000),
      });
      const user = object(await auth.json().catch(() => null));
      if (!auth.ok || typeof user?.id !== "string" || !uuid.test(user.id) || user.is_anonymous === true) {
        throw new RequestFailure(401, "invalid_session");
      }
      const job = object(await rpc("siab_claim_push_event", {
        p_actor_id: user.id, p_event_type: input.event_type, p_record_id: input.record_id,
      }));
      if (job?.status === "already_sent") return json(200, { accepted: true, status: "already_sent" });
      if (job?.status === "in_progress" || job?.status === "no_recipients") {
        return json(202, { accepted: false, status: job.status });
      }
      if (job?.status === "no_event") return json(409, { accepted: false, status: "event_unavailable" });
      const recipients = job?.recipient_external_ids;
      if (job?.status !== "ready" || typeof job.event_id !== "string" || !uuid.test(job.event_id) ||
          !Number.isSafeInteger(job.siswa_id) || Number(job.siswa_id) <= 0 ||
          !Array.isArray(recipients) || recipients.length < 1 || recipients.length > 2000 ||
          !recipients.every((id) => typeof id === "string" && /^[a-f0-9]{64}$/.test(id))) {
        throw new RequestFailure(502, "invalid_event");
      }
      claimedId = job.event_id;
      const letter = input.event_type === "letter_decision";
      const key = config.restKey.trim();
      const keyHeader = /^(Key|Basic) /.test(key) ? key : `${key.startsWith("os_v2_") ? "Key" : "Basic"} ${key}`;
      const provider = await fetcher("https://api.onesignal.com/notifications", {
        method: "POST", signal: AbortSignal.timeout(10000),
        headers: { "Content-Type": "application/json", Authorization: keyHeader },
        body: JSON.stringify({
          app_id: config.appId, target_channel: "push", idempotency_key: claimedId,
          include_aliases: { external_id: [...new Set(recipients)] },
          headings: { en: letter ? "Keputusan surat tersedia" : "Presensi diperbarui" },
          contents: { en: "Buka aplikasi untuk melihat informasi terbaru ananda." },
          data: { type: letter ? "surat" : "absensi", siswa_id: job.siswa_id,
            event_id: claimedId, ...(letter ? { surat_id: input.record_id } : {}) },
        }),
      });
      const receipt = object(await provider.json().catch(() => null));
      const accepted = provider.ok && typeof receipt?.id === "string" && uuid.test(receipt.id) &&
        !receipt.errors && (receipt.recipients === undefined || Number(receipt.recipients) > 0);
      await rpc("siab_finish_push_event", { p_event_id: claimedId,
        p_success: accepted, p_provider_id: accepted ? receipt!.id : null });
      claimedId = null;
      return accepted ? json(200, { accepted: true, status: "sent" })
        : json(502, { accepted: false, error: "provider_rejected" });
    } catch (error) {
      if (claimedId) {
        await rpc("siab_finish_push_event", { p_event_id: claimedId,
          p_success: false, p_provider_id: null }).catch(() => {});
      }
      return error instanceof RequestFailure
        ? json(error.status, { error: error.code })
        : json(502, { error: "delivery_unavailable" });
    }
  };
}
