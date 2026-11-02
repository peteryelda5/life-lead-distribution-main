'use strict';
const {JSDOM}=require('jsdom'),fs=require('fs'),assert=require('node:assert/strict');
const dom=new JSDOM('<main id="app"></main>',{url:'https://example.test',runScripts:'outside-only'}),w=dom.window,calls=[];
let waiting,release,fail=false,pending=null;
const initial={id:'job',source:'agency',mode:'folder',folder:'Folder <img>',states:null,total:1501,assigned:100,processed:0,returned:0,skipped:0,summary:[{state:'MI',count:1501,assigned:100}],started_at:null,finished_at:null};
let server=structuredClone(initial);
Object.assign(w,{S:{profile:{id:'master',role:'admin',is_super_admin:true},selected:new Set(),divisionDirectory:[{id:'agency',name:'Test Agency'}]},portalSessionEpoch:1,
 q:s=>w.document.querySelector(s),esc:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),reload:async m=>calls.push({reload:m}),flash:()=>{},
 api:async(path,{body})=>{calls.push({path,body});if(path.endsWith('_options'))return [{type:initial.folder,count:1501,states:[{state:'MI',count:1501,pool:1401,assigned:100}]}];if(path.endsWith('_bulk_status'))return pending;
 if(path.endsWith('_bulk_prepare'))return structuredClone(initial);
 if(path.endsWith('_bulk_stop')){pending=null;return {...server,cancelled:true}};
 if(path.endsWith('_bulk_step')){if(waiting)await waiting;if(body.p_offset===server.processed){server.processed=Math.min(server.total,server.processed+1000);server.returned=server.processed;server.started_at='started';if(server.processed===server.total)server.finished_at='done'}if(fail){fail=false;throw Error('Network interrupted')}return structuredClone(server)};
 throw Error('Unexpected RPC '+path);}});
const app=fs.readFileSync('portal-app.js','utf8');for(const name of ['modal','closeModal'])w.eval(app.split('\n').find(x=>x.startsWith('function '+name+'(')));
w.eval(fs.readFileSync('agency-recall-bulk.js','utf8'));w.eval(fs.readFileSync('agency-recall.js','utf8'));
(async()=>{
 await w.openAgencyRecall('agency');w.q('#recallAmount').value='folder';w.q('#recallAmount').onchange();assert(w.q('#recallPreviewButton').disabled);assert(w.q('#recallScope').disabled);assert(w.q('#recallAllStates').disabled);assert(w.q('#recallCountField').hidden);
 w.q('#recallType').value='0';w.q('#recallType').onchange();assert(!w.q('#recallPreviewButton').disabled);assert.match(w.q('#recallQuantityHelp').textContent,/1,501/);await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});
 assert.deepEqual(JSON.parse(JSON.stringify(calls.at(-1).body)),{p_source:'agency',p_type:'Folder <img>',p_scope:'all',p_states:null,p_mode:'folder'});assert.equal(w.document.querySelectorAll('#modal').length,1);assert(!w.q('img'));assert.match(w.q('#recallBulk').textContent,/Folder <img>/);assert(!calls.some(x=>x.path?.endsWith('_bulk_step')));
 w.q('#recallBulkClose').click();assert(!w.q('#modal'));
 await w.openAgencyRecall('agency');w.q('#recallAmount').value='matching';w.q('#recallAmount').onchange();assert(!w.q('#recallAllStates').disabled);w.q('.recallState').checked=true;w.q('.recallState').onchange();await w.q('#agencyRecallForm').onsubmit({preventDefault(){}});assert.equal(calls.at(-1).body.p_mode,'matching');assert.deepEqual(Array.from(calls.at(-1).body.p_states),['MI']);
 waiting=new Promise(r=>release=r);const run=w.q('#recallBulkConfirm').onclick();assert(w.q('#recallBulkConfirm').disabled);w.q('#recallBulkClose').click();release();await run;waiting=null;assert.match(w.q('#recallBulkMessage').textContent,/Paused/);assert.match(w.q('#recallBulkCounts').textContent,/1,000 returned/);assert.equal(calls.filter(x=>x.path?.endsWith('_bulk_step')).length,1);
 // The server completed a group but the response was lost. Retry must not move another group.
 fail=true;await w.q('#recallBulkConfirm').onclick();assert.match(w.q('#recallBulkMessage').textContent,/Network interrupted/);assert.equal(server.processed,1501);await w.q('#recallBulkConfirm').onclick();assert.match(w.q('#recallBulkTitle').textContent,/complete/);assert.match(w.q('#recallBulkCounts').textContent,/1,501 returned/);await w.q('#recallBulkClose').onclick();assert(calls.some(x=>x.reload?.includes('1,501')));
 pending={...initial,processed:1000,returned:1000,started_at:'started'};await w.openAgencyRecall('agency');assert(w.q('#recallBulk'));assert.match(w.q('#recallBulkConfirm').textContent,/Resume/);await w.q('#recallBulkStop').onclick();assert(w.q('#agencyRecallForm'),'Stopping a partial take-back reopens filters');
 console.log('PASS: whole-folder validation, state filtering, accurate count, explicit review, real Cancel, no stacked dialogs, progress, pause/resume, lost-response retry and stop.');dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1});
