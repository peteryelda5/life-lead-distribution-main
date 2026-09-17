import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,auth=req.headers.get("Authorization")??"";
 const caller=createClient(url,anon,{global:{headers:{Authorization:auth}}});
 const {data:{user},error:uerr}=await caller.auth.getUser();if(uerr||!user)return json({error:"Unauthorized"},401);
 const {data:cp}=await caller.from("profiles").select("role,active,is_super_admin,division").eq("id",user.id).single();
 if(!cp||cp.role!=="admin"||!cp.active)return json({error:"Admin only"},403);
 const body=await req.json().catch(()=>({}));
 const full_name=String(body.full_name??"").trim(),email=String(body.email??"").trim().toLowerCase(),password=String(body.password??"");
 const {data:allowedDivisions,error:scopeError}=await caller.rpc("my_admin_divisions");
 if(scopeError||!Array.isArray(allowedDivisions))return json({error:"Could not verify division permissions"},403);
 let division=String(body.division??cp.division??"").trim();
 if(!full_name||!email||!password)return json({error:"Full name, email and temporary password are required"},400);
 if(password.length<8)return json({error:"Temporary password must be at least 8 characters"},400);
 if(!["owner","vivid_life","legacy_life"].includes(division))return json({error:"Invalid division"},400);
 if(!allowedDivisions.includes(division))return json({error:"You cannot manage that division"},403);
 const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
 const {data:existing,error:lookupError}=await admin.from("profiles").select("id,email,full_name,role,active,archived,division,is_super_admin").eq("email",email).maybeSingle();
 if(lookupError)return json({error:"Could not check the existing account. Try again."},500);
 if(existing){
  if(existing.role!=="agent"||existing.is_super_admin||!existing.archived||existing.active||!allowedDivisions.includes(existing.division))return json({error:"This email already belongs to an account. Contact the Master Admin if it needs review."},409);
  if(body.restore!==true)return json({error:"This agent was removed but their account was kept to preserve history.",code:"AGENT_ARCHIVED",division:existing.division},409);
  const {error:authError}=await admin.auth.admin.updateUserById(existing.id,{password});
  if(authError)return json({error:authError.message},400);
  const {data:restored,error:restoreError}=await admin.from("profiles").update({active:true,archived:false}).eq("id",existing.id).eq("role","agent").eq("division",existing.division).eq("archived",true).eq("active",false).select("id,email,full_name,active,division").maybeSingle();
  if(restoreError||!restored)return json({error:"Could not restore the agent. Their password was updated; contact the Master Admin before retrying."},409);
  await admin.from("audit_logs").insert({actor_id:user.id,action:"agent_restored",entity_type:"profile",entity_id:existing.id,details:{division:existing.division}});
  return json({agent:restored,restored:true});
 }
 if(body.restore===true)return json({error:"The archived account could not be found. Start again."},409);
 const {data,error}=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{full_name}});if(error||!data.user)return json({error:error?.message??"Could not create agent"},400);
 const {error:perr}=await admin.from("profiles").upsert({id:data.user.id,email:data.user.email,full_name,role:"agent",active:true,archived:false,is_super_admin:false,created_by_admin_id:user.id,division});
 if(perr){await admin.auth.admin.deleteUser(data.user.id);return json({error:perr.message},400)}
 await admin.from("audit_logs").insert({actor_id:user.id,action:"agent_created",entity_type:"profile",entity_id:data.user.id,details:{email:data.user.email,division}});
 return json({agent:{id:data.user.id,email:data.user.email,full_name,active:true,division}});
});
