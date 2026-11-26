import { createSendPushHandler } from "./handler.ts";

Deno.serve(createSendPushHandler({
  projectUrl: (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, ""),
  anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  appId: Deno.env.get("ONESIGNAL_APP_ID") ?? "",
  restKey: Deno.env.get("ONESIGNAL_REST_API_KEY") ?? "",
}));
