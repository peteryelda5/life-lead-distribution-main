'use strict';
const assert=require('node:assert/strict'),{createHmac}=require('node:crypto');
const user='11111111-1111-4111-8111-111111111111',session='22222222-2222-4222-8222-222222222222',source='33333333-3333-4333-8333-333333333333',id='44444444-4444-4444-8444-444444444444',other='55555555-5555-4555-8555-555555555555';
const account='AC'+'a'.repeat(32),callSid='CA'+'b'.repeat(32),gt='GT'+'c'.repeat(32),ga='GA'+'d'.repeat(32),ly='LY'+'e'.repeat(32),lead='66666666-6666-4666-8666-666666666666';
const ctx={TWILIO_ACCOUNT_SID:account,TWILIO_AUTH_TOKEN:'fixture-secret'},u={id:user,sessionId:session,live:true};
let rows=[],dbQueries=[],events=[],streams=0,serviceExists=false,attached=false,stopped=false,failCreate=false,active=true;
const failure=(status,message)=>Object.assign(Error(message),{status});
const database=async(path,body,method)=>{
 dbQueries.push({path,body,method});const [table,q]=path.split('?'),p=new URLSearchParams(q),eq=k=>(p.get(k)||'').replace(/^eq\./,'');
 if(table==='leads')return [{id:lead}];
 if(table==='dialer_conversation_lines')return [{sequence:1,speaker:'client',spoken_at:new Date().toISOString(),content:'Please call tomorrow.'}];
 if(table!=='dialer_conversations')throw Error('Unexpected DB '+table);
 let selected=rows.filter(r=>(!p.has('id')||r.id===eq('id'))&&(!p.has('user_id')||r.user_id===eq('user_id'))&&(!p.has('source_id')||r.source_id===eq('source_id'))&&(!p.has('provider_sid')||r.provider_sid===eq('provider_sid'))&&(!p.has('call_sid')||r.call_sid===eq('call_sid')));
 if(method==='PATCH'){for(const r of selected)Object.assign(r,body);}return selected.map(r=>({...r}));
};
const rpc=async(name,b)=>{
 if(name==='dialer_conversation_claim'){if(rows.length)return{created:false,conversation:rows[0]};rows.push({...b.p_data,id,state:'starting',created_at:new Date().toISOString(),expires_at:new Date(Date.now()+86400000).toISOString()});return{created:true,conversation:rows[0]};}
 if(name==='dialer_conversation_event'){events.push(b);rows[0].transcription_sid=b.p_transcription;if(b.p_event==='transcription-started'&&rows[0].state==='starting')rows[0].state='live';return null;}
 throw Error('Unexpected RPC '+name);
};
require.cache[require.resolve('../lib/dialer-full')]={exports:{database,rpc,failure,config:()=>ctx,mode:()=>true,UUID:/^[a-f0-9-]{36}$/,ORIGIN:'https://www.lldportal.com',MASTER:other}};
require.cache[require.resolve('../lib/dialer-at-cost-provider')]={exports:{context:async()=>ctx,callbackContext:async()=>ctx,scoped:async(who,path,body)=>{
 assert.equal(who.id,user);if(path===`Calls/${callSid}.json`)return{account_sid:account,status:active?'in-progress':'completed',to:'+12025550191'};
 if(path.endsWith('/Transcriptions.json')){streams++;assert.equal(body.Track,'both_tracks');assert.equal(body.InboundTrackLabel,'Client');assert.equal(body.OutboundTrackLabel,'Agent');assert.equal(body.IntelligenceService,ga);assert.equal(body.StatusCallbackUrl,`https://www.lldportal.com/api/dialer/conversation-events?id=${id}`);if(failCreate)throw failure(503,'Timeout');return{sid:gt,account_sid:account,call_sid:callSid};}
 if(path.includes('/Transcriptions/')){if(body){assert.equal(body.Status,'stopped');stopped=true;}return{sid:gt,account_sid:account,call_sid:callSid,status:stopped?'stopped':'in-progress'};}
 throw Error('Unexpected provider '+path);
}}};
require.cache[require.resolve('../lib/dialer-parallel')]={exports:{get:async(i,owner)=>{if(owner!==user)throw failure(404,'Not found');return{user_id:user,session_id:session,state:active?'connected':'complete',winner_id:'winner',legs:[{id:'winner',provider_sid:callSid,phone:'+12025550191',lead_id:lead}]};},alive:()=>active,storedContext:async()=>ctx}};
global.fetch=async(url,opt={})=>{const path=url.split('/v2/')[1],body=Object.fromEntries(new URLSearchParams(opt.body));let data,status=200;
 if(path==='Services/lld-agent-conversations-v1'){if(!serviceExists){data={code:20404};status=404;}else data={sid:ga,account_sid:account,unique_name:'lld-agent-conversations-v1',auto_transcribe:false,data_logging:false,read_only_attached_operator_sids:attached?[ly]:[]};}
 else if(path==='Services'){assert.equal(body.AutoTranscribe,'false');assert.equal(body.DataLogging,'false');serviceExists=true;data={sid:ga,account_sid:account,unique_name:body.UniqueName,auto_transcribe:false,data_logging:false};}
 else if(path.startsWith('Operators/PreBuilt'))data={prebuilt_operators:[{sid:ly,friendly_name:'Summarization',availability:'public'}]};
 else if(path===`Services/${ga}/Operators/${ly}`){attached=true;data={operator_sid:ly};}
 else if(path.startsWith(`Transcripts/${gt}/OperatorResults`))data={operator_results:[{operator_sid:'LY'+'f'.repeat(32),transcript_sid:gt,text_generation_results:{result:'Wrong operator'}},{operator_sid:ly,transcript_sid:gt,text_generation_results:{result:'The client requested a callback tomorrow.'}}]};
 else throw Error('Unexpected CI '+path);
 return new Response(JSON.stringify(data),{status});};
const app=require('../lib/dialer-conversations');const action=b=>app.action({body:b},u),base={kind:'power',id:source};
async function reject(fn,status){await assert.rejects(fn,e=>e.status===status);}
(async()=>{
 await reject(()=>action({...base,action:'start'}),400);assert.equal(streams,0);
 await reject(()=>action({...base,action:'setup'}),403);
 let r=await action({...base,action:'state'});assert.equal(r.conversation,null);assert.equal(streams,0);
 active=false;await reject(()=>action({...base,action:'start',consent:true,acceptCharges:true}),409);active=true;
 r=await action({...base,action:'start',consent:true,acceptCharges:true});assert.equal(streams,1);assert.equal(r.conversation.state,'live');assert.equal(r.conversation.phone,'+12025550191');assert.equal(r.conversation.transcription_sid,undefined);
 await action({...base,action:'start',consent:true,acceptCharges:true});assert.equal(streams,1,'Repeated Start created a second stream');
 await reject(()=>app.action({body:{...base,action:'start',consent:true,acceptCharges:true}},{...u,id:other}),404);
 r=await app.action({body:{...base,action:'state'}},{...u,id:other});assert.equal(r.conversation,null,'Another agent read this transcript');
 r=await action({...base,action:'stop'});assert.equal(stopped,true);assert.equal(r.conversation.summary,'The client requested a callback tomorrow.');
 const event={AccountSid:account,CallSid:callSid,TranscriptionSid:gt,TranscriptionEvent:'transcription-content',TranscriptionData:JSON.stringify({transcript:'<img src=x>Client words'}),Track:'inbound_track',SequenceId:'7',Timestamp:new Date().toISOString(),Final:'true'};
 const route='/api/dialer/conversation-events?id='+id;
 const send=async(b,signed=true)=>{let raw='https://www.lldportal.com'+route;for(const k of Object.keys(b).sort())raw+=k+b[k];const res={setHeader(){},status(n){this.code=n;return this;},end(){return this;}};await app.events({method:'POST',url:route,body:b,headers:{'content-type':'application/x-www-form-urlencoded','x-twilio-signature':signed?createHmac('sha1',ctx.TWILIO_AUTH_TOKEN).update(raw).digest('base64'):'invalid'}},res);return res;};
 assert.equal((await send(event,false)).code,403);assert.equal((await send({...event,CallSid:'CA'+'f'.repeat(32)})).code,403);assert.equal((await send({...event,TranscriptionSid:'GT'+'f'.repeat(32)})).code,403);
 assert.equal((await send({...event,Final:'false'})).code,204);const prior=events.length;assert.equal((await send(event)).code,204);assert.equal(events.length,prior+1);assert.equal(events.at(-1).p_content,'<img src=x>Client words');
 // An uncertain provider response cannot be retried into another paid stream.
 rows=[];failCreate=true;r=await action({...base,action:'start',consent:true,acceptCharges:true});assert.equal(r.conversation.state,'starting');await action({...base,action:'start',consent:true,acceptCharges:true});assert.equal(streams,2);
 for(const q of dbQueries.filter(x=>x.path.includes('source_id=')))assert.match(q.path,/user_id=eq\./);
 console.log('PASS: consent, active-call and owner checks, account-scoped CI setup, no automatic transcription, duplicate/uncertain-start protection, stop, exact summary operator, signed callbacks and call binding.');
})().catch(e=>{console.error(e);process.exitCode=1;});
