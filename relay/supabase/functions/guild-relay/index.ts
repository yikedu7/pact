import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-guild-admin",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_PER_HOUR = 30;
const PROJECT_URL = Deno.env.get("SUPABASE_URL")!;
const BOOTSTRAP_ADMIN = Deno.env.get("GUILD_RELAY_ADMIN") ?? ""; // set via Edge secret; never commit real value

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function clientIp(req: Request): string {
  return (
    req.headers.get("cf-connecting-ip") ||
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    "unknown"
  );
}

function pathParts(url: URL): string[] {
  return url.pathname.split("/").filter(Boolean);
}

function afterRelay(url: URL): string[] {
  const parts = pathParts(url);
  const idx = parts.lastIndexOf("guild-relay");
  if (idx < 0) return [];
  return parts.slice(idx + 1).map((p) => decodeURIComponent(p));
}

function adminClient() {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return createClient(PROJECT_URL, legacy);
  const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
  const key = secretKeys["default"];
  if (!key) throw new Error("missing service role key");
  return createClient(PROJECT_URL, key);
}

function expectedAdmin(): string {
  return Deno.env.get("GUILD_RELAY_ADMIN") || BOOTSTRAP_ADMIN;
}

function checkAdmin(req: Request): boolean {
  const h = req.headers.get("x-guild-admin") || "";
  return h.length > 0 && h === expectedAdmin();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = new URL(req.url);
  const rest = afterRelay(url);
  const supabase = adminClient();

  if (rest[0] === "_admin" && rest[1] === "register") {
    if (!checkAdmin(req)) return json(401, { error: "unauthorized" });
    let body: {
      bot_id?: string;
      webhook_url?: string;
      webhook_key?: string;
      enabled?: boolean;
    };
    try {
      body = await req.json();
    } catch {
      return json(400, { error: "invalid JSON body" });
    }
    const botId = body.bot_id?.trim();
    const webhookUrl = body.webhook_url?.trim();
    const webhookKey = body.webhook_key;
    if (!botId || !webhookUrl || !webhookKey) {
      return json(400, { error: "bot_id, webhook_url, webhook_key required" });
    }
    if (typeof webhookKey !== "string" || webhookKey.length < 20) {
      return json(400, { error: "webhook_key looks too short" });
    }
    const { error } = await supabase.from("guild_bots").upsert(
      {
        bot_id: botId,
        webhook_url: webhookUrl,
        webhook_key: webhookKey,
        enabled: body.enabled !== false,
      },
      { onConflict: "bot_id" },
    );
    if (error) return json(500, { error: error.message });
    return json(200, {
      ok: true,
      bot_id: botId,
      webhook_url: webhookUrl,
      key_len: webhookKey.length,
      enabled: body.enabled !== false,
    });
  }

  const botId = rest[0] || url.searchParams.get("botId");
  if (!botId || botId.startsWith("_")) {
    return json(400, { error: "missing botId in path: /guild-relay/<botId>" });
  }

  let envelope: unknown;
  try {
    envelope = await req.json();
  } catch {
    return json(400, { error: "invalid JSON body" });
  }
  if (!envelope || typeof envelope !== "object") {
    return json(400, { error: "body must be a JSON object" });
  }
  const proto = (envelope as { protocol?: string }).protocol;
  if (proto !== "guild.negotiate/v0.1" && proto !== "guild.escrow/v0.1") {
    return json(400, { error: "protocol must be guild.negotiate/v0.1 or guild.escrow/v0.1" });
  }

  const { data: bot, error: botErr } = await supabase
    .from("guild_bots")
    .select("bot_id, webhook_url, webhook_key, enabled")
    .eq("bot_id", botId)
    .maybeSingle();
  if (botErr) return json(500, { error: botErr.message });
  if (!bot || !bot.enabled) {
    return json(404, { error: "unknown or disabled botId" });
  }
  if (!bot.webhook_key || bot.webhook_key.length < 20) {
    return json(502, {
      error: "bot registered but webhook_key invalid; re-register",
      key_len: bot.webhook_key?.length ?? 0,
    });
  }

  const ip = clientIp(req);
  const windowStart = new Date();
  windowStart.setMinutes(0, 0, 0);

  const { data: existing } = await supabase
    .from("guild_relay_rate_limits")
    .select("id, hit_count")
    .eq("bot_id", botId)
    .eq("client_ip", ip)
    .eq("window_start", windowStart.toISOString())
    .maybeSingle();

  if (existing && existing.hit_count >= MAX_PER_HOUR) {
    return json(429, {
      error: "rate limit exceeded",
      limit: MAX_PER_HOUR,
      window: "hour",
    });
  }
  if (existing) {
    await supabase
      .from("guild_relay_rate_limits")
      .update({ hit_count: existing.hit_count + 1 })
      .eq("id", existing.id);
  } else {
    await supabase.from("guild_relay_rate_limits").insert({
      bot_id: botId,
      client_ip: ip,
      window_start: windowStart.toISOString(),
      hit_count: 1,
    });
  }

  const { data: allBots } = await supabase
    .from("guild_bots")
    .select("bot_id, webhook_url")
    .eq("enabled", true);
  const env = envelope as { callback_url?: string; [k: string]: unknown };
  if (typeof env.callback_url === "string" && allBots) {
    for (const peer of allBots) {
      if (env.callback_url === peer.webhook_url) {
        env.callback_url =
          `${PROJECT_URL}/functions/v1/guild-relay/${peer.bot_id}`;
        break;
      }
    }
  }

  const upstream = await fetch(bot.webhook_url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${bot.webhook_key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(env),
  });

  const text = await upstream.text();
  let upstreamBody: unknown = text;
  try {
    upstreamBody = JSON.parse(text);
  } catch {
    /* keep text */
  }

  return new Response(
    JSON.stringify({
      ok: upstream.ok,
      bot_id: botId,
      upstream_status: upstream.status,
      upstream: upstreamBody,
    }),
    {
      status: upstream.ok ? 200 : 502,
      headers: { ...cors, "Content-Type": "application/json" },
    },
  );
});
