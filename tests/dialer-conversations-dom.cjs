'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const flush=async()=>{for(let i=0;i<8;i++)await new Promise(r=>setImmediate(r));};
(async()=>{
 const dom=new JSDOM('<div id="root"><div class="workspace-toolbar"></div><dialog id="powerConnectedDialog"><div id="powerDialogBody"><div id="powerConversationSlot"></div><div id="powerSummarySlot"></div></div></dialog></div>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;let instance;
 try{
 Object.defineProperty(w.document,'hidden',{value:false});w.AbortSignal=AbortSignal;const owner='11111111-1111-4111-8111-111111111111';w.localStorage.setItem('lld_session',JSON.stringify({user:{id:owner}}));let current=null,row=null,added=[],requests=[],lines=[],timers=[];
 w.setInterval=fn=>{timers.push(fn);return 1;};w.clearInterval=()=>{};
 w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);requests.push(b);if(b.action==='start')row={id:'transcript',phone:'Test number',state:'live',leadId:'lead'};if(b.action==='stop')row={...row,state:'stopped',summary:'Client requested a callback.'};return{ok:true,json:async()=>({conversation:row,lines})};};
 w.eval(fs.readFileSync(__dirname+'/../dialer-conversations.js','utf8'));const root=w.document.querySelector('#root'),$=id=>root.querySelector('#'+id);
 instance=w.createDialerConversations(root,{owner,getSession:async()=>({access_token:'fixture'}),getCall:()=>current,canAddNotes:id=>id==='lead',addNotes:(id,text)=>{added.push({id,text});return true;}});
 assert.equal($('conversationStart').disabled,true);current={kind:'power',id:'batch',active:true,label:'Test number'};await timers[0]();await flush();assert.equal(requests.some(r=>r.action==='start'),false);assert.equal($('conversationStart').disabled,true);
 $('conversationAgreed').checked=true;$('conversationAgreed').dispatchEvent(new w.Event('change'));$('conversationStart').click();await flush();assert.equal(requests.filter(r=>r.action==='start').length,1);assert.equal($('conversationStop').hidden,false);
 // The panel follows the modal without recreating the stream or losing state.
 $('powerConnectedDialog').open=true;instance.changed();assert.equal($('powerConversationSlot').querySelector('.conversation-panel'),root.querySelector('.conversation-panel'));assert.equal($('powerSummarySlot').querySelector('#conversationSummarySection'),$('conversationSummarySection'));assert.equal($('conversationSummarySection').open,false);$('powerConnectedDialog').open=false;instance.changed();assert.ok(root.querySelector('.conversation-anchor .conversation-panel'));assert.ok(root.querySelector('.conversation-panel #conversationSummarySection'));assert.equal($('conversationSummarySection').open,true);
 lines=[{sequence:1,speaker:'client',content:'<img src=x onerror=alert(1)>',spoken_at:new Date().toISOString()}];row.summary='Client requested a callback.';row.state='stopped';current=null;
 $('powerConnectedDialog').open=true;instance.changed();
 // Explicit Stop fetches finished text; it does not hang up the call.
 $('conversationStop').click();await flush();assert.equal(root.querySelector('img'),null);assert.match($('conversationLines').textContent,/Client/);assert.equal($('conversationSummary').value,'Client requested a callback.');assert.equal(added.length,0);assert.equal($('conversationSummarySection').open,true);assert.equal($('conversationSummary').closest('#powerSummarySlot'),$('powerSummarySlot'));
 $('conversationSummary').value='Reviewed callback tomorrow at noon.';$('conversationAdd').click();assert.equal(added[0].text,'[AI call summary — reviewed]\nReviewed callback tomorrow at noon.');
 $('powerConnectedDialog').open=false;instance.changed();assert.equal($('conversationSummary').value,'Reviewed callback tomorrow at noon.');
 // A new call resets consent and draft. It never starts transcription by itself.
 current={kind:'call',id:'next',active:true,label:'Next call'};row=null;lines=[];await timers[0]();await flush();assert.equal($('conversationAgreed').checked,false);assert.equal($('conversationSummary').value,'');assert.equal(requests.filter(r=>r.action==='start').length,1);
 w.localStorage.setItem('lld_session',JSON.stringify({user:{id:'other'}}));await timers[0]();assert.equal(root.querySelector('.conversation-panel'),null);
 console.log('PASS: explicit consent/start, active-call gating, two-speaker text rendering, XSS safety, sidebar transcript/summary relocation, automatic summary disclosure, draft preservation, review-before-notes, new-call consent reset, account-change cleanup.');
 }finally{instance?.dispose();w.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
