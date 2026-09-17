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
 const body=await req.json().catch(()=>({})); const agentId=String(body?.agent_id??"").trim(); if(!agentId)return json({error:"agent_id is required"},400);
 const {data:agent,error:agentError}=await admin.from("profiles").select("id,email,full_name,role,division").eq("id",agentId).single();
 if(agentError||!agent||agent.role!=="agent")return json({error:"Agent not found"},404);
 const {data:canManage,error:scopeError}=await caller.rpc("admin_can_manage_agent",{target_agent:agentId});
 if(scopeError||canManage!==true)return json({error:"You cannot manage this agent"},403);
 const {data:factorsData,error:factorsError}=await admin.auth.admin.mfa.listFactors({userId:agentId}); if(factorsError)return json({error:factorsError.message},400);
 const factors=factorsData?.factors??[]; let removed=0; for(const factor of factors){const {error}=await admin.auth.admin.mfa.deleteFactor({userId:agentId,id:factor.id});if(error)return json({error:error.message},400);removed++;}
 await admin.from("audit_logs").insert({actor_id:user.id,action:"agent_mfa_reset",entity_type:"profile",entity_id:agentId,details:{removed_factors:removed,agent_email:agent.email,division:agent.division}});
 return json({ok:true,removed_factors:removed,agent_id:agentId});
});
