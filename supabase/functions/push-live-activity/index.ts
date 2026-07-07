import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const APNS_KEY_ID   = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID  = Deno.env.get("APNS_TEAM_ID")!;
const APNS_BUNDLE_ID = "com.barbecuez.app";
const APNS_TOPIC    = `${APNS_BUNDLE_ID}.push-type.liveactivity`;
const APNS_KEY_P8   = Deno.env.get("APNS_AUTH_KEY")!;  // full .p8 file content

// ── APNs JWT ────────────────────────────────────────────────────────────────

async function makeApnsJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  const headerB64 = b64url(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
  const payloadB64 = b64url(JSON.stringify({ iss: APNS_TEAM_ID, iat: now }));

  const keyData = APNS_KEY_P8
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  const binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const sigBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(`${headerB64}.${payloadB64}`),
  );

  const sigB64 = b64url(new Uint8Array(sigBuf));
  return `${headerB64}.${payloadB64}.${sigB64}`;
}

function b64url(input: string | Uint8Array): string {
  const str = typeof input === "string"
    ? btoa(input)
    : btoa(String.fromCharCode(...input));
  return str.replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

// ── Handler ─────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400 });
  }

  const {
    orderId,
    status,
    statusLabel,
    etaMinutes,
    progress,
    driverName,
    driverPhone,
    dismiss,
  } = body as Record<string, unknown>;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: tokens, error } = await sb
    .from("live_activity_tokens")
    .select("*")
    .eq("order_id", orderId);

  if (error || !tokens?.length) {
    return new Response(JSON.stringify({ sent: 0, reason: error?.message ?? "no tokens" }), {
      headers: { "content-type": "application/json" },
    });
  }

  const jwt = await makeApnsJwt();
  const results: { token: string; status: number }[] = [];

  for (const t of tokens) {
    const payload = {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: dismiss ? "end" : "update",
        "content-state": {
          status,
          statusLabel,
          etaMinutes,
          progress: progress ?? 0.5,
          driverName:  driverName  ?? null,
          driverPhone: driverPhone ?? null,
        },
        ...(dismiss
          ? { "dismissal-date": Math.floor(Date.now() / 1000) + 60 }
          : {}),
      },
    };

    const res = await fetch(
      `https://api.push.apple.com/3/device/${t.push_token}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "liveactivity",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      },
    );

    results.push({ token: (t.push_token as string).slice(0, 8) + "…", status: res.status });
  }

  return new Response(JSON.stringify({ sent: results.length, results }), {
    headers: { "content-type": "application/json" },
  });
});
