// export-notion — creates a Notion page from a meeting's summary.
//
// The Notion integration token lives ONLY here, as the `NOTION_TOKEN` Edge
// Function secret. The (non-secret) target database id is read from the user's
// `user_settings` row.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const NOTION_TOKEN = Deno.env.get("NOTION_TOKEN") ?? "";
const NOTION_VERSION = "2022-06-28";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    if (!NOTION_TOKEN) return json({ error: "NOTION_TOKEN secret is not set." }, 500);

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
    if (!meeting.summary) return json({ error: "Meeting has no summary to export" }, 400);

    const { data: settings } = await admin
      .from("user_settings").select("notion_database_id").eq("user_id", user.id).maybeSingle();
    const databaseId = settings?.notion_database_id;
    if (!databaseId) return json({ error: "No Notion database configured in Settings" }, 400);

    const resp = await fetch("https://api.notion.com/v1/pages", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${NOTION_TOKEN}`,
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(buildPage(databaseId, meeting)),
    });
    if (!resp.ok) return json({ error: `Notion ${resp.status}: ${await resp.text()}` }, 502);

    const page = await resp.json();
    await admin.from("meetings").update({
      notion_page_url: page.url, status: "exported",
    }).eq("id", meeting_id).eq("user_id", user.id);

    return json({ url: page.url });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function buildPage(databaseId: string, meeting: any) {
  const s = meeting.summary;
  const emoji: Record<string, string> = { high: "🔴", medium: "🟡", low: "🟢" };
  const order: Record<string, number> = { high: 0, medium: 1, low: 2 };
  const rt = (t: string) => [{ type: "text", text: { content: String(t).slice(0, 1990) } }];

  const children: any[] = [
    { object: "block", type: "heading_2", heading_2: { rich_text: rt("📝 Summary") } },
    { object: "block", type: "paragraph", paragraph: { rich_text: rt(s.summary ?? "") } },
  ];

  if (Array.isArray(s.key_points) && s.key_points.length) {
    children.push({ object: "block", type: "heading_2", heading_2: { rich_text: rt("📌 Key points") } });
    for (const p of s.key_points) {
      children.push({ object: "block", type: "bulleted_list_item", bulleted_list_item: { rich_text: rt(p) } });
    }
  }

  if (Array.isArray(s.next_steps) && s.next_steps.length) {
    children.push({ object: "block", type: "heading_2", heading_2: { rich_text: rt("✅ Next steps & priorities") } });
    const steps = [...s.next_steps].sort((a, b) => (order[a.priority] ?? 9) - (order[b.priority] ?? 9));
    for (const step of steps) {
      const parts = [`${emoji[step.priority] ?? ""} ${step.task}`];
      if (step.owner) parts.push(`— ${step.owner}`);
      if (step.due) parts.push(`(${step.due})`);
      children.push({
        object: "block", type: "to_do",
        to_do: { rich_text: rt(parts.join(" ")), checked: false },
      });
    }
  }

  children.push({ object: "block", type: "divider", divider: {} });
  const date = new Date(meeting.started_at).toLocaleString();
  children.push({ object: "block", type: "paragraph", paragraph: { rich_text: rt(`Recorded with Winday Notetaker • ${date}`) } });

  return {
    parent: { database_id: databaseId },
    properties: { title: { title: rt(s.headline ?? meeting.title) } },
    children,
  };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
}
