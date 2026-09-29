import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";

  const caller = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userError } = await caller.auth.getUser();
  if (userError || !user) return json({ error: "Unauthorized" }, 401);
  const {data:mfaAllowed,error:mfaError}=await caller.rpc("require_portal_mfa");
  if(mfaError||mfaAllowed!==true)return json({error:"Two-step verification required. Sign in and verify your authenticator code."},403);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: callerProfile } = await admin
    .from("profiles")
    .select("role,active,is_super_admin")
    .eq("id", user.id)
    .single();
  if (!callerProfile || callerProfile.role !== "admin" || !callerProfile.active || callerProfile.is_super_admin !== true) {
    return json({ error: "Super admin only" }, 403);
  }

  const body = await req.json().catch(() => ({}));
  const adminId = String(body?.admin_id ?? "").trim();
  if (!adminId) return json({ error: "admin_id is required" }, 400);
  if (adminId === user.id) return json({ error: "You cannot remove your own Super Admin account" }, 400);

  const { data: targetProfile, error: targetError } = await admin
    .from("profiles")
    .select("id,email,full_name,role,is_super_admin")
    .eq("id", adminId)
    .single();
  if (targetError || !targetProfile || targetProfile.role !== "admin" || targetProfile.is_super_admin === true) {
    return json({ error: "Scoped admin not found" }, 404);
  }

  // Delete login first. If this fails, no ownership changes have been made.
  const { error: deleteAuthError } = await admin.auth.admin.deleteUser(adminId);
  if (deleteAuthError) return json({ error: deleteAuthError.message }, 400);

  // Keep the removed admin's team and data by transferring ownership to the Super Admin.
  const { error: teamError } = await admin
    .from("profiles")
    .update({ created_by_admin_id: user.id })
    .eq("created_by_admin_id", adminId);
  if (teamError) return json({ error: "Admin login removed, but team transfer failed: " + teamError.message }, 500);

  const { error: leadError } = await admin
    .from("leads")
    .update({ owner_admin_id: user.id })
    .eq("owner_admin_id", adminId);
  if (leadError) return json({ error: "Admin login removed, but lead transfer failed: " + leadError.message }, 500);

  const { error: profileDeleteError } = await admin
    .from("profiles")
    .delete()
    .eq("id", adminId)
    .eq("role", "admin")
    .eq("is_super_admin", false);
  if (profileDeleteError) return json({ error: "Admin login removed, but profile cleanup failed: " + profileDeleteError.message }, 500);

  await admin.from("audit_logs").insert({
    actor_id: user.id,
    action: "scoped_admin_removed",
    entity_type: "profile",
    entity_id: adminId,
    details: {
      removed_email: targetProfile.email,
      removed_name: targetProfile.full_name,
      team_transferred_to_super_admin: true,
    },
  });

  return json({ ok: true, removed_admin_id: adminId });
});