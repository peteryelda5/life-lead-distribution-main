const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');for(const s of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))new vm.Script(s[1]);
const code=fs.readFileSync('supabase/functions/create-agent/index.ts','utf8').replace(/^import .*;\n/gm,'').replace(':unknown','').replace(':Request','').replace(/\)!/g,')');
async function run(cp,existing,body={},authFail=false){let handler;const writes=[];
function from(table){let op='read';const chain={select(){return this},eq(){return this},update(v){op='update';writes.push(v);return this},async maybeSingle(){return {data:op==='update'?{...existing,active:true,archived:false}:existing}},async insert(v){writes.push(v);return {}},async single(){return {data:cp}}};return chain}
const caller={rpc:async()=>({data:cp?.divisions||(cp?.is_super_admin?['owner','vivid_life','legacy_life']:[cp?.division])}),auth:{getUser:async()=>({data:{user:cp?{id:'admin'}:null}})},from};
const admin={from,auth:{admin:{updateUserById:async(id,values)=>{writes.push({passwordChanged:id});return {error:authFail?{message:'Password failed'}:null}},createUser:async()=>{writes.push({created:true});return {error:{message:'mock create'}}}}}};
const ctx={Request,Response,console,Deno:{env:{get:x=>x},serve:f=>handler=f},createClient:(url,key)=>key==='SUPABASE_SERVICE_ROLE_KEY'?admin:caller};vm.createContext(ctx);vm.runInContext(code,ctx);
const res=await handler(new Request('https://example.test',{method:'POST',body:JSON.stringify({email:'test@example.test',password:'longpassword',full_name:'Test',division:cp?.division||'vivid_life',...body})}));return {status:res.status,body:await res.json(),writes};}
(async()=>{const master={role:'admin',active:true,is_super_admin:true,division:'vivid_life'},legacy={...master,is_super_admin:false,division:'legacy_life'},agent={id:'archived',role:'agent',active:false,archived:true,is_super_admin:false,division:'owner'};
let r=await run(master,agent);assert.equal(r.body.code,'AGENT_ARCHIVED');assert.equal(r.writes.length,0);
r=await run(master,agent,{restore:true});assert.equal(r.status,200);assert.equal(r.body.agent.division,'owner');assert.equal(r.body.restored,true);assert(!r.writes.some(x=>'division'in x));
r=await run(legacy,agent,{restore:true});assert.equal(r.status,409);assert.equal(r.writes.length,0);
r=await run(master,{...agent,role:'admin'},{restore:true});assert.equal(r.status,409);assert.equal(r.writes.length,0);
r=await run(master,{...agent,active:true,archived:false},{restore:true});assert.equal(r.status,409);assert.equal(r.writes.length,0);
r=await run(master,agent,{restore:true},true);assert.equal(r.status,400);assert.equal(r.writes.length,1);
r=await run(null,agent,{restore:true});assert.equal(r.status,401);assert.equal(r.writes.length,0);
r=await run({...master,active:false},agent,{restore:true});assert.equal(r.status,403);assert.equal(r.writes.length,0);
r=await run(legacy,{...agent,division:'legacy_life'},{restore:true});assert.equal(r.status,200);
r=await run({...legacy,division:'vivid_life',divisions:['owner','vivid_life']},agent,{division:'owner',restore:true});assert.equal(r.status,200);r=await run({...legacy,division:'vivid_life',divisions:['owner','vivid_life']},null,{division:'legacy_life'});assert.equal(r.status,403);assert.equal(r.writes.length,0);
console.log('PASS: syntax, restore confirmation, original division preserved, scoped admin isolation, admin/active-account protection, auth failure, inactive/anonymous rejection');})().catch(e=>{console.error(e);process.exit(1)});
