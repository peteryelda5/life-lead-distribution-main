const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const source=fs.readFileSync('portal-app.js','utf8');
const fn=source.slice(source.indexOf('async function deleteBatchColumns(){'),source.indexOf('\nfunction headingSaveKey()'));
async function test(){
 const dom=new JSDOM('<button id="editBatchHeadings"></button>',{url:'https://example.test',runScripts:'outside-only'}),w=dom.window;
 let calls=[],fail=true,loaded=0;
 w.S={profile:{id:'admin-test'},poolLeads:[{id:'sample',lead_type:'Demo',csv_filename:'demo.csv',csv_headers:['Name','Extra <tag>','Phone'],csv_values:['A','B','C']}]};
 w.q=s=>w.document.querySelector(s);w.jsonArray=x=>x;w.readHeadingSave=()=>null;w.flash=()=>{};w.render=()=>{};
 w.loadPoolPage=async()=>loaded++;w.esc=x=>String(x??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
 w.api=async(path,req)=>{calls.push(JSON.parse(JSON.stringify(req.body)));if(fail){fail=false;throw Error('Connection interrupted')}return {updated:2,done:true}};
 w.eval(fn+';window.openDelete=deleteBatchColumns');
 await w.openDelete();
 assert.equal(w.q('#columnChoices tag'),null);
 const submit=()=>w.q('#columnDeleteForm').onsubmit({preventDefault(){}});
 await submit();assert.equal(calls.length,0);
 const choice=w.q('.columnRemove[value="1"]');choice.checked=true;choice.onchange();
 assert.match(w.q('#columnReview').textContent,/Extra <tag>/);
 await submit();assert.equal(calls.length,0);
 w.q('#columnConfirm').checked=true;await submit();
 assert.equal(calls.length,1);assert.ok(w.sessionStorage.getItem('vivid_column_delete_v1:admin-test'));
 w.q('#columnCancel').click();assert.equal(w.q('#headingPanel'),null);
 await w.openDelete();assert.equal(w.q('#columnSubmit').textContent,'Resume deletion');
 await submit();assert.equal(calls.length,2);assert.deepEqual(calls[1],calls[0]);assert.deepEqual(calls[0].p_remove,[1]);
 assert.equal(w.sessionStorage.length,0);assert.equal(loaded,1);assert.equal(w.q('#headingPanel'),null);
 await w.openDelete();w.q('#columnCancel').click();assert.equal(w.q('#headingPanel'),null);
 console.log('PASS: escaped labels, explicit review, selected column indices, interrupted deletion resume, stable retry, refresh and cancel');
}
test().catch(e=>{console.error(e);process.exitCode=1});
