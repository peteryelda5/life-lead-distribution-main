'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const flush=async()=>{for(let i=0;i<12;i++)await new Promise(r=>setImmediate(r));};
(async()=>{
 const dom=new JSDOM('<div id="root"><div class="workspace-toolbar"></div></div>',{url:'https://www.lldportal.com',runScripts:'outside-only'}),w=dom.window;
 let ops;try{
 const owner='11111111-1111-4111-8111-111111111111';w.localStorage.setItem('lld_session',JSON.stringify({user:{id:owner}}));w.AbortSignal=AbortSignal;
 let serverMode='ready',hold=null,fail=false;const requests=[],timers=[];
 w.setInterval=fn=>{timers.push(fn);return 1;};w.clearInterval=()=>{};
 w.fetch=async(url,opt)=>{const b=JSON.parse(opt.body);requests.push(b);if(b.action==='priority')return{ok:true,json:async()=>({tasks:[]})};
  if(hold){const wait=hold;hold=null;await wait;}if(fail){fail=false;return{ok:false,json:async()=>({error:'Connection lost'})};}
  if(b.mode)serverMode=b.mode;return{ok:true,json:async()=>({mode:serverMode,supervisor:false})};};
 w.eval(fs.readFileSync(__dirname+'/../dialer-operations.js','utf8'));const root=w.document.querySelector('#root');
 ops=w.createDialerOperations(root,{owner,getSession:async()=>({access_token:'fixture'}),getActivity:()=> 'idle',getLead:()=>null,onChange:()=>{},openView:()=>{}});await flush();
 const select=root.querySelector('#agentMode');assert.equal(ops.canDial(),true);
 // Native selects can change selection before firing change (keyboard / open popup).
 select.focus();select.value='break';ops.changed();assert.equal(select.value,'break','Background refresh overwrote the user’s in-progress selection');
 // A heartbeat in flight must not undo a new choice or leave calls enabled.
 let release;hold=new Promise(r=>{release=r;});timers[0]();await flush();select.dispatchEvent(new w.Event('change'));assert.equal(ops.canDial(),false,'New calls remained allowed while Break was queued');
 assert.equal(select.value,'break','Pending selection snapped back');release();await flush();assert.equal(serverMode,'break');assert.equal(select.value,'break');assert.equal(ops.mode(),'break');
 for(let i=0;i<3;i++){timers[0]();await flush();}assert.equal(serverMode,'break');assert.equal(select.value,'break');
 select.value='offline';select.dispatchEvent(new w.Event('change'));await flush();assert.equal(serverMode,'offline');assert.equal(ops.canDial(),false);
 // Failed saves must be visible, remain fail-closed, and retry the requested mode.
 fail=true;select.value='ready';select.dispatchEvent(new w.Event('change'));await flush();assert.equal(ops.canDial(),false);assert.equal(select.value,'ready');assert.match(root.querySelector('#agentStateHint').textContent,/retry|saving|connection/i);
 timers[0]();await flush();assert.equal(serverMode,'ready');assert.equal(ops.canDial(),true);
 // Two fast explicit selections during an in-flight request: latest choice wins.
 hold=new Promise(r=>{release=r;});select.value='break';select.dispatchEvent(new w.Event('change'));await flush();select.value='offline';select.dispatchEvent(new w.Event('change'));release();await flush();assert.equal(serverMode,'offline');assert.equal(select.value,'offline');
 const choices=requests.filter(r=>r.mode).map(r=>r.mode);assert.deepEqual(choices.slice(-2),['break','offline']);
 console.log('PASS: refresh-safe availability selection, queued Break blocks dialing, heartbeat persistence, Offline, failed-save retry, latest choice wins.');
 }finally{ops?.dispose();w.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
