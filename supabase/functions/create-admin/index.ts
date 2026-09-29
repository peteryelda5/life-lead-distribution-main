import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST") return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, auth=req.headers.get("Authorization")??"";
 const caller=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:{user},error:uerr}=await caller.auth.getUser(); if(uerr||!user)return json({error:"Unauthorized"},401);
 const {data:mfaAllowed,error:mfaError}=await caller.rpc("require_portal_mfa");
 if(mfaError||mfaAllowed!==true)return json({error:"Two-step verification required. Sign in and verify your authenticator code."},403);
 const {data:cp}=await caller.from("profiles").select("role,active,is_super_admin").eq("id",user.id).single();
 if(!cp||cp.role!=="admin"||!cp.active||!cp.is_super_admin)return json({error:"Super admin only"},403);
 const body=await req.json().catch(()=>({}));
 const full_name=String(body.full_name??"").trim(), email=String(body.email??"").trim().toLowerCase(), password=String(body.password??""), division=String(body.division??"").trim();
 if(!full_name||!email||!password)return json({error:"Full name, email and temporary password are required"},400);
 if(password.length<8)return json({error:"Temporary password must be at least 8 characters"},400);
 const {data:divisionIds,error:divisionError}=await caller.rpc("my_admin_divisions");
 if(divisionError||!Array.isArray(divisionIds))return json({error:"Could not verify division permissions"},403);
 if(division==="owner"||!divisionIds.includes(division))return json({error:"Choose an existing division"},400);
 const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
 const {data,error}=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{full_name}});
 if(error||!data.user)return json({error:error?.message??"Could not create admin"},400);
 const {error:perr}=await admin.from("profiles").upsert({id:data.user.id,email:data.user.email,full_name,role:"admin",active:true,archived:false,is_super_admin:false,created_by_admin_id:user.id,division});
 if(perr){await admin.auth.admin.deleteUser(data.user.id);return json({error:perr.message},400)}
 await admin.from("audit_logs").insert({actor_id:user.id,action:"scoped_admin_created",entity_type:"profile",entity_id:data.user.id,details:{email:data.user.email,division}});
 return json({admin:{id:data.user.id,email:data.user.email,full_name,active:true,division}});
});
