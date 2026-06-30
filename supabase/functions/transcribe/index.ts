// transcribe — uploads a recorded meeting's audio to Deepgram (Nova-3) and
// stores the diarized transcript on the meeting row.
//
// The Deepgram API key lives ONLY here, as the `DEEPGRAM_API_KEY` Edge Function
// secret. It is never shipped to the macOS app.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEEPGRAM_API_KEY = Deno.env.get("DEEPGRAM_API_KEY") ?? "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    if (!DEEPGRAM_API_KEY) return json({ error: "DEEPGRAM_API_KEY secret is not set." }, 500);

    // Authenticate the caller from their JWT.
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { meeting_id } = await req.json();

    // Load the meeting (scoped to the caller) + their model preference.
    const { data: meeting, error: mErr } = await admin
      .from("meetings").select("*").eq("id", meeting_id).eq("user_id", user.id).single();
    if (mErr || !meeting) return json({ error: "Meeting not found" }, 404);
    if (!meeting.audio_path) return json({ error: "Meeting has no audio_path" }, 400);

    const { data: settings } = await admin
      .from("user_settings").select("deepgram_model").eq("user_id", user.id).maybeSingle();
    const model = settings?.deepgram_model || "nova-3";

    // Short-lived signed URL so Deepgram can fetch the private recording.
    const { data: signed, error: sErr } = await admin.storage
      .from("recordings").createSignedUrl(meeting.audio_path, 600);
    if (sErr || !signed) return json({ error: "Could not sign audio URL" }, 500);

    const dgUrl = new URL("https://api.deepgram.com/v1/listen");
    for (const [k, v] of Object.entries({
      model, smart_format: "true", punctuate: "true",
      diarize: "true", utterances: "true", detect_language: "true",
    })) dgUrl.searchParams.set(k, v);

    const dgResp = await fetch(dgUrl, {
      method: "POST",
      headers: { Authorization: `Token ${DEEPGRAM_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ url: signed.signedUrl }),
    });
    if (!dgResp.ok) return json({ error: `Deepgram ${dgResp.status}: ${await dgResp.text()}` }, 502);

    const dg = await dgResp.json();
    const channel = dg?.results?.channels?.[0];
    const alt = channel?.alternatives?.[0];
    const utterances = (dg?.results?.utterances ?? []).map((u: any) => ({
      speaker: u.speaker ?? 0, text: u.transcript, start: u.start, end: u.end,
    }));
    const transcript = {
      fullText: alt?.transcript ?? "",
      utterances,
      language: channel?.detected_language ?? null,
    };

    await admin.from("meetings").update({
      transcript, language: transcript.language, status: "summarizing", error_message: null,
    }).eq("id", meeting_id).eq("user_id", user.id);

    return json({ transcript });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
}
