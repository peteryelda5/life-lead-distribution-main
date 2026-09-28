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
 const {data:cp}=await caller.from("profiles").select("role,active,is_super_admin").eq("id",user.id).single();if(!cp||cp.role!=="admin"||!cp.active||!cp.is_super_admin)return json({error:"Super admin only"},403);
 const body=await req.json().catch(()=>({}));const admin_id=String(body.admin_id??"").trim(),full_name=String(body.full_name??"").trim(),email=String(body.email??"").trim().toLowerCase(),division=String(body.division??"").trim();
 if(!admin_id||!full_name||!email)return json({error:"Admin, full name and email are required"},400);
 const {data:divisionIds,error:divisionError}=await caller.rpc("my_admin_divisions");
 if(divisionError||!Array.isArray(divisionIds))return json({error:"Could not verify division permissions"},403);
 if(division==="owner"||!divisionIds.includes(division))return json({error:"Choose an existing division"},400);
 const svc=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
 const {data:target}=await svc.from("profiles").select("id,email,full_name,role,is_super_admin").eq("id",admin_id).single();if(!target||target.role!=="admin"||target.is_super_admin)return json({error:"Scoped admin not found"},404);
 const {data:authData,error:ferr}=await svc.auth.admin.getUserById(admin_id);if(ferr||!authData.user)return json({error:ferr?.message??"Admin login account not found"},400);
 const oldEmail=authData.user.email??target.email??"",oldMeta=authData.user.user_metadata??{};
 const {error:aerr}=await svc.auth.admin.updateUserById(admin_id,{email,user_metadata:{...oldMeta,full_name}});if(aerr)return json({error:aerr.message},400);
 const {error:perr}=await svc.from("profiles").update({full_name,email,division}).eq("id",admin_id).eq("role","admin").eq("is_super_admin",false);
 if(perr){await svc.auth.admin.updateUserById(admin_id,{email:oldEmail,user_metadata:oldMeta});return json({error:perr.message},400)}
 await svc.from("audit_logs").insert({actor_id:user.id,action:"scoped_admin_updated",entity_type:"profile",entity_id:admin_id,details:{new_email:email,new_name:full_name,division}});
 return json({admin:{id:admin_id,full_name,email,division}});
});
