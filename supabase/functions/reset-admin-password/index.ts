import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({error:"Method not allowed"},405);
  const url=Deno.env.get("SUPABASE_URL")!;
  const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
  const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader=req.headers.get("Authorization")??"";
  const caller=createClient(url,anon,{global:{headers:{Authorization:authHeader}}});
  const {data:{user},error:userError}=await caller.auth.getUser();
  if(userError||!user)return json({error:"Unauthorized"},401);
 const {data:mfaAllowed,error:mfaError}=await caller.rpc("require_portal_mfa");
 if(mfaError||mfaAllowed!==true)return json({error:"Two-step verification required. Sign in and verify your authenticator code."},403);
  const {data:profile}=await caller.from("profiles").select("role,active,is_super_admin").eq("id",user.id).single();
  if(!profile||profile.role!=="admin"||!profile.active||!profile.is_super_admin)return json({error:"Super admin only"},403);
  const body=await req.json().catch(()=>({}));
  const adminId=String(body?.admin_id??"").trim();
  const password=String(body?.password??"");
  if(!adminId||!password)return json({error:"Admin and new temporary password are required"},400);
  if(password.length<8)return json({error:"Temporary password must be at least 8 characters"},400);
  const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
  const {data:target,error:targetError}=await admin.from("profiles").select("id,email,full_name,role,is_super_admin").eq("id",adminId).single();
  if(targetError||!target||target.role!=="admin"||target.is_super_admin)return json({error:"Scoped admin not found"},404);
  const {error:updateError}=await admin.auth.admin.updateUserById(adminId,{password});
  if(updateError)return json({error:updateError.message},400);
  await admin.from("audit_logs").insert({actor_id:user.id,action:"scoped_admin_password_reset",entity_type:"profile",entity_id:adminId,details:{email:target.email}});
  return json({ok:true,admin_id:adminId});
});
