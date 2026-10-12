'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {JSDOM,ResourceLoader,VirtualConsole}=require('jsdom');
const root=path.resolve(__dirname,'..'),html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const errors=[],requested=[];
class Assets extends ResourceLoader{
 fetch(url){const u=new URL(url);requested.push(u.pathname);
  if(u.hostname==='cdn.jsdelivr.net')return Promise.resolve(Buffer.from('window.supabase={createClient:()=>({auth:{},realtime:{setAuth:async()=>{}},removeChannel(){}})};'));
  assert.equal(u.hostname,'portal.test');
  if(!u.pathname.endsWith('.js'))return Promise.resolve(Buffer.from(''));
  return Promise.resolve(fs.readFileSync(path.join(root,u.pathname)));
 }
}
(async()=>{
 const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
 const dom=new JSDOM(html,{url:'https://portal.test/',runScripts:'dangerously',resources:new Assets(),pretendToBeVisual:true,virtualConsole:vc});
 try{
  await new Promise(resolve=>dom.window.addEventListener('load',resolve,{once:true}));
  const doc=dom.window.document;
  assert.equal(errors.length,0,errors.join('\n'));
  assert(doc.querySelector('input[type="password"]'),'The real deferred script order must reach the sign-in form.');
  assert(requested.includes('/portal-app.js'));
  assert([...doc.scripts].filter(s=>s.src).every(s=>s.defer),'Every startup asset is deferred.');
  for(const name of ['loadCore','loadDashboard','loadAgentDashboard','loadChat','pcPoll','bobLoad','navigatePortalTab'])assert.equal(dom.window.eval('typeof '+name),'function',name);
  assert.equal(dom.window.eval('portalNavigationBusy'),false);
  console.log('PASS: real HTML and deferred script order start without errors; sign-in and all main page loaders are available.');
 }finally{dom.window.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
