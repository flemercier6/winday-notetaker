// transcribe — uploads a recorded meeting's audio to Deepgram (Nova-3) and
// stores the transcript.
//
// The recording is a stereo WAV where channel 0 is the user's mic and channel 1
// is the meeting audio. We use `multichannel=true` so Deepgram transcribes each
// channel independently (channel 0 = "You", channel 1 = the others), plus
// `diarize=true` so multiple remote participants on channel 1 are split too.
//
// Backend: this runs against the Winday CRM's own Supabase project and writes to
// its existing `meetings` table. That table stores `transcript`/`summary` as
// human-readable TEXT columns; the structured payload (utterances, language, …)
// is kept in the `metadata` jsonb column so nothing is lost.
//
// The Deepgram API key lives ONLY here, as the `DEEPGRAM_API_KEY` secret.
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

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { meeting_id, deepgram_model } = await req.json();
    const model = deepgram_model || "nova-3";

    const { data: meeting, error: mErr } = await admin
      .from("meetings").select("*").eq("id", meeting_id).eq("user_id", user.id).single();
    if (mErr || !meeting) return json({ error: "Meeting not found" }, 404);
    if (!meeting.audio_path) return json({ error: "Meeting has no audio_path" }, 400);

    const { data: signed, error: sErr } = await admin.storage
      .from("recordings").createSignedUrl(meeting.audio_path, 600);
    if (sErr || !signed) return json({ error: "Could not sign audio URL" }, 500);

    const dgUrl = new URL("https://api.deepgram.com/v1/listen");
    for (const [k, v] of Object.entries({
      model,
      multichannel: "true",
      diarize: "true",
      punctuate: "true",
      utterances: "true",
      smart_format: "true",
      detect_language: "true",
    })) dgUrl.searchParams.set(k, v);

    const dgResp = await fetch(dgUrl, {
      method: "POST",
      headers: { Authorization: `Token ${DEEPGRAM_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ url: signed.signedUrl }),
    });
    if (!dgResp.ok) return json({ error: `Deepgram ${dgResp.status}: ${await dgResp.text()}` }, 502);

    const dg = await dgResp.json();

    // Build labelled utterances. Channel 0 = you, channel 1 = the meeting
    // (diarized into Participant 1, 2, …).
    const raw = (dg?.results?.utterances ?? []).slice().sort(
      (a: any, b: any) => (a.start ?? 0) - (b.start ?? 0));
    const utterances = raw.map((u: any) => ({
      speaker: (u.channel ?? 0) === 0 ? "You" : `Participant ${(u.speaker ?? 0) + 1}`,
      text: u.transcript ?? "",
      start: u.start ?? 0,
      end: u.end ?? 0,
    })).filter((u: any) => u.text.trim().length > 0);

    const fullText = utterances.map((u: any) => u.text).join(" ");
    const language = dg?.results?.channels?.[0]?.detected_language ?? null;

    // Structured payload the app + CRM UI consume.
    const transcript = { fullText, utterances, language };
    // Human-readable transcript for the CRM's TEXT column.
    const labelled = utterances.map((u: any) => `${u.speaker}: ${u.text}`).join("\n");

    const metadata = { ...(meeting.metadata ?? {}), transcript, language };

    await admin.from("meetings").update({
      transcript: labelled,
      metadata,
      status: "summarizing",
      last_error: null,
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
