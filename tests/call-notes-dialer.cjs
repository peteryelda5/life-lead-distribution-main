'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 const dom=new JSDOM('<body><div id="portalDialer"></div></body>',{url:'https://portal.test',runScripts:'outside-only'}),w=dom.window;
 let instance;try{
  const session={user:{id:'agent'},access_token:'test'};w.localStorage.setItem('lld_session',JSON.stringify(session));w.S={session,profile:{id:'agent'},leads:[]};w.portalSessionEpoch=0;w.confirm=()=>false;w.AbortSignal=AbortSignal;
  const lead={id:'lead-one',first_name:'Test',lead_type:'Test folder',agent_status:null,call_notes:null,state:'TX'},order=[];let failNotes=false;
  w.api=async(path,opt)=>{order.push('note');if(failNotes)throw Error('Offline');assert.equal(opt.body.p_expected_notes,lead.call_notes);lead.call_notes=opt.body.p_notes;return {saved:true,notes:lead.call_notes};};
  w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);let data;
   if(url.includes('/account'))data={ownerExempt:true,entitled:true,realCallingAllowed:true,numbers:[],usedMinutes:0};
   else if(b.action==='profile')data={profile:{full_name:'Test',division:'vivid_life'},scripts:[]};
   else if(b.action==='folders')data={folders:[{lead_type:'Test folder',lead_count:1}]};
   else if(b.action==='leads')data={leads:[{...lead}],count:1,states:[{state:'TX',lead_count:1}]};
   else if(b.action==='save'){order.push('outcome');assert.equal(b.expectedNotes,lead.call_notes);assert.equal(b.notes,lead.call_notes);lead.agent_status=b.status;data={lead:{...lead}};}
   else throw Error('Unexpected test API: '+url+' '+b.action);
   return {ok:true,json:async()=>data};
  };
  w.eval(fs.readFileSync(__dirname+'/../call-notes.js','utf8'));w.eval(fs.readFileSync(__dirname+'/../portal-dialer.js','utf8'));
  const root=w.document.getElementById('portalDialer');instance=w.createPortalDialer(root);await tick();await tick();
  root.querySelector('#queue button').click();const notes=root.querySelector('#notes'),right=root.querySelector('#notesRight');
  right.value='Autosave in dialer';right.dispatchEvent(new w.Event('input'));assert.equal(notes.value,right.value);assert.equal(instance.canLeave(),true,'Notes drafts can survive changing tabs without a discard prompt');
  root.querySelector('#outcome').value='call_back';root.querySelector('#save').click();await tick();await tick();assert.deepEqual(order,['note','outcome']);assert.equal(lead.call_notes,'Autosave in dialer');assert.equal(lead.agent_status,'call_back');assert(root.textContent.includes('Saved to the original lead'));
  failNotes=true;notes.value='Keep this on failure';notes.dispatchEvent(new w.Event('input'));root.querySelector('#outcome').value='not_interested';root.querySelector('#save').click();await tick();await tick();assert.deepEqual(order,['note','outcome','note']);assert.equal(lead.agent_status,'call_back');assert.equal(notes.value,'Keep this on failure');assert(root.querySelector('#message').textContent.includes('resolve the call notes'));
  failNotes=false;assert.equal(await w.PortalCallNotes.flush('lead-one'),true);root.querySelector('#save').click();await tick();await tick();assert.equal(lead.agent_status,'not_interested');assert.equal(lead.call_notes,'Keep this on failure');
  console.log('PASS: actual dialer DOM shares notes, preserves drafts, waits for note acknowledgement before outcome saves and blocks outcomes on note failure.');
 }finally{instance?.dispose();dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
