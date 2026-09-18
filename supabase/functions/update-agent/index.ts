import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,authHeader=req.headers.get("Authorization")??"";
 const caller=createClient(url,anon,{global:{headers:{Authorization:authHeader}}});
 const {data:{user},error:userError}=await caller.auth.getUser(); if(userError||!user)return json({error:"Unauthorized"},401);
 const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
 const {data:callerProfile}=await admin.from("profiles").select("role,active,is_super_admin,division").eq("id",user.id).single();
 if(!callerProfile||callerProfile.role!=="admin"||!callerProfile.active)return json({error:"Admin only"},403);
 const body=await req.json().catch(()=>({})); const agentId=String(body?.agent_id??"").trim(),fullName=String(body?.full_name??"").trim(),email=String(body?.email??"").trim().toLowerCase();
 if(!agentId||!fullName||!email)return json({error:"Agent, full name and email are required"},400);
 const {data:target,error:targetError}=await admin.from("profiles").select("id,email,full_name,role,active,archived,division").eq("id",agentId).single();
 if(targetError||!target||target.role!=="agent")return json({error:"Agent not found"},404);
 const {data:canManage,error:scopeError}=await caller.rpc("admin_can_manage_agent",{target_agent:agentId});
 if(scopeError||canManage!==true)return json({error:"You cannot manage this agent"},403);
 if(target.archived)return json({error:"Archived agents cannot be edited"},400);
 const {data:authData,error:authFetchError}=await admin.auth.admin.getUserById(agentId); if(authFetchError||!authData.user)return json({error:authFetchError?.message??"Agent login account not found"},400);
 const originalEmail=authData.user.email??target.email??"",originalMeta=authData.user.user_metadata??{};
 const {error:authUpdateError}=await admin.auth.admin.updateUserById(agentId,{email,user_metadata:{...originalMeta,full_name:fullName}}); if(authUpdateError)return json({error:authUpdateError.message},400);
 const {error:profileError}=await admin.from("profiles").update({full_name:fullName,email}).eq("id",agentId).eq("role","agent");
 if(profileError){await admin.auth.admin.updateUserById(agentId,{email:originalEmail,user_metadata:originalMeta});return json({error:profileError.message},400);}
 await admin.from("audit_logs").insert({actor_id:user.id,action:"agent_updated",entity_type:"profile",entity_id:agentId,details:{new_email:email,new_name:fullName,division:target.division}});
 return json({agent:{id:agentId,full_name:fullName,email,active:target.active,division:target.division}});
});
