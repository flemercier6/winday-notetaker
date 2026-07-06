// summarize — sends a meeting's diarized transcript to Gemini (Flash) and
// stores the structured summary (headline, summary, key points, next steps).
//
// The Gemini API key lives ONLY here, as the `GEMINI_API_KEY` Edge Function
// secret.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";

const responseSchema = {
  type: "OBJECT",
  properties: {
    headline: { type: "STRING" },
    summary: { type: "STRING" },
    key_points: { type: "ARRAY", items: { type: "STRING" } },
    next_steps: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          task: { type: "STRING" },
          owner: { type: "STRING" },
          priority: { type: "STRING", enum: ["high", "medium", "low"] },
          due: { type: "STRING" },
        },
        required: ["task", "priority"],
      },
    },
  },
  required: ["headline", "summary", "key_points", "next_steps"],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    if (!GEMINI_API_KEY) return json({ error: "GEMINI_API_KEY secret is not set." }, 500);

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { meeting_id } = await req.json();

    const { data: meeting, error: mErr } = await admin
      .from("meetings").select("*").eq("id", meeting_id).eq("user_id", user.id).single();
    if (mErr || !meeting) return json({ error: "Meeting not found" }, 404);
    if (!meeting.transcript?.utterances) return json({ error: "Meeting has no transcript yet" }, 400);

    const { data: settings } = await admin
      .from("user_settings").select("gemini_model").eq("user_id", user.id).maybeSingle();
    const model = settings?.gemini_model || "gemini-flash-latest";

    const labelled = meeting.transcript.utterances
      .map((u: any) => `${u.speaker}: ${u.text}`).join("\n");

    const prompt = `You are an expert sales/meeting assistant for Winday CRM. Analyze the ` +
      `following meeting transcript and produce structured notes. The speaker labelled ` +
      `"You" is the app's user; "Participant 1/2/…" are the other attendees. Be concise ` +
      `and action-oriented. For next_steps, infer the owner when possible (the user vs a ` +
      `participant) and assign a realistic priority. Write in the same language as the ` +
      `transcript.\n\nMeeting title: ${meeting.title}\n\nTRANSCRIPT:\n${labelled}`;

    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
      {
        method: "POST",
        headers: { "x-goog-api-key": GEMINI_API_KEY, "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.3,
            responseMimeType: "application/json",
            responseSchema,
          },
        }),
      },
    );
    if (!resp.ok) return json({ error: `Gemini ${resp.status}: ${await resp.text()}` }, 502);

    const data = await resp.json();
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!text) return json({ error: "Gemini returned no content" }, 502);
    const summary = JSON.parse(text);

    await admin.from("meetings").update({
      summary,
      title: summary.headline || meeting.title,
      status: "ready",
      error_message: null,
    }).eq("id", meeting_id).eq("user_id", user.id);

    return json({ summary });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
}
