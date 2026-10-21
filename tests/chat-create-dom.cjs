'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const root=__dirname+'/../',source=['chat-media.js','live-chat.js','chat-social.js','portal-collaboration.js'].map(f=>fs.readFileSync(root+f,'utf8')).join('\n');
const css=fs.readFileSync(root+'portal-collaboration.css','utf8');
const people=[{id:'one',name:'Matthew B.',division:'united_life'},{id:'two',name:'Maxsim Kassab',division:'vivid_life'},{id:'three',name:'Mía',division:'united_life'}];
const tick=async()=>{for(let i=0;i<8;i++)await new Promise(r=>setImmediate(r));};
function setup(){
 const dom=new JSDOM('<head><style>'+css+'</style></head><body><div id="app"></div></body>',{url:'https://www.lldportal.com',runScripts:'outside-only',pretendToBeVisual:true}),w=dom.window;
 const calls=[],flashes=[],chats=[];let failLists=0,failCreate=false;
 w.q=s=>w.document.querySelector(s);w.qa=s=>[...w.document.querySelectorAll(s)];w.esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 w.S={profile:{id:'owner',role:'admin',division:'vivid_life',active:true},tab:'live-chat',session:{}};
 w.divisionLabel=x=>({vivid_life:'Vivid Life',united_life:'United Life'}[x]||x);w.adminDivisionList=()=>['vivid_life'];w.currentAal=()=> 'aal2';
 w.loadDashboard=w.loadAgentDashboard=async()=>{};w.dash=w.agentDashboardPage=()=>'';w.bindDashboard=w.bindAgentDashboard=()=>{};
 w.flash=(s,error)=>flashes.push({s,error});w.PortalNotifications={};w.scrollTo=()=>{};
 w.modal=html=>w.document.body.insertAdjacentHTML('beforeend','<div id="modal"><div class="modalbox">'+html+'</div></div>');w.closeModal=()=>w.q('#modal')?.remove();
 w.api=async(path,opt={})=>{
  const a=opt.body?.p_action,d=opt.body?.p_data||{};calls.push({path,a,d});
  if(path==='/rest/v1/rpc/portal_collaboration'){
   if(a==='people')return structuredClone(people);
   if(a==='create'){
    if(failCreate)throw Error('Temporary connection error');
    const c={id:'chat-'+(chats.length+1),name:d.name,kind:d.kind,members:['owner',...d.members],owner_id:'owner',unread:0};chats.push(c);return {id:c.id};
   }
   if(a==='list'){if(failLists-->0)throw Error('Chat list unavailable');return {chats:structuredClone(chats),channels:[]};}
   if(a==='messages')return [];
   if(a==='add_members'){const c=chats.find(c=>c.id===d.id);c.members.push(...d.members);return {};}
   return {};
  }
  return [];
 };
 w.eval(source+'\nwindow.testState={PC,CHAT,SOCIAL};startChat=async()=>{};');
 const {PC,CHAT}=w.testState;PC.owner='owner';CHAT.owner='owner';CHAT.division='all';CHAT.scopes=['vivid_life','united_life'];
 w.render=()=>{w.q('#app').innerHTML=w.chatPage();w.bindChat();};w.render();
 const $=id=>w.document.getElementById(id),input=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new w.Event('input',{bubbles:true}));};
 const select=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new w.Event('change',{bubbles:true}));};
 return {w,dom,$,input,select,PC,CHAT,calls,chats,flashes,failLists(n){failLists=n;},failCreate(v){failCreate=v;},async open(add=false){await w.pcCreateChat(add);await tick();},async submit(){await $('pcCreateForm').onsubmit({preventDefault(){}});await tick();},choose(id){w.q('.pc-member-list input[value="'+id+'"]').click();},close(){dom.window.close();}};
}
(async()=>{
 let h=setup();try{
  await h.open();h.input('pcMemberSearch','mia');
  const row=h.w.q('[data-member-name="matthew b."]');assert.equal(h.w.getComputedStyle(row).display,'none','non-matching member must be visually hidden');
  assert.equal(h.w.qa('.pc-member-list label').filter(r=>h.w.getComputedStyle(r).display!=='none').length,1);
  h.input('pcMemberSearch','  UNITED   life  ');assert.equal(h.w.qa('.pc-member-list label').filter(r=>!r.hidden).length,2,'agency search and extra spaces');
  h.input('pcMemberSearch','zzzz');assert.match(h.$('pcMemberEmpty').textContent,/No members/);assert.equal(h.$('pcMemberEmpty').hidden,false);
  h.input('pcMemberSearch','');h.select('pcKind','direct');h.choose('one');h.choose('two');assert.equal(h.w.qa('.pc-member-list input:checked').length,1,'direct message has a single recipient');
  await h.submit();assert.equal(h.calls.filter(x=>x.a==='create').length,1);assert.deepEqual(h.chats[0].members,['owner','two']);assert.equal(h.PC.group,h.chats[0].id);assert.equal(h.$('pcCreateForm'),null);assert.match(h.w.q('.chat-head').textContent,/Maxsim Kassab/);
  await h.w.loadChat();await tick();assert.equal(h.PC.chats.length,1,'saved chat reloaded');
 }finally{h.close();}
 h=setup();try{
  await h.open();await h.submit();assert.match(h.$('pcCreateError').textContent,/Choose|Select/);assert.equal(h.calls.filter(x=>x.a==='create').length,0);
  h.choose('one');await h.submit();assert.match(h.$('pcCreateError').textContent,/name/);
  h.input('pcName','Leadership');h.choose('two');h.input('pcMemberSearch','Mia');assert.equal(h.w.qa('.pc-member-list input:checked').length,2,'filter keeps selected members');
  h.failLists(1);await h.submit();assert.equal(h.chats.length,1,'group saved before list failure');assert.match(h.$('pcCreateError').textContent,/saved/i);assert.equal(h.$('pcCreateSave').textContent,'Open chat');
  await h.submit();assert.equal(h.chats.length,1,'retry opens saved chat without duplicating');assert.equal(h.PC.group,h.chats[0].id);assert.equal(h.$('pcCreateForm'),null);
  const search=h.$('pcChatSearch');search.value='unmatched';search.dispatchEvent(new h.w.Event('input'));assert.equal(h.w.getComputedStyle(h.w.q('[data-pc-room]')).display,'none','sidebar search hides unmatched saved chats');
 }finally{h.close();}
 h=setup();try{
  await h.open();h.select('pcKind','direct');h.choose('one');h.failCreate(true);await h.submit();assert.match(h.$('pcCreateError').textContent,/Temporary/);assert.equal(h.$('pcCreateSave').disabled,false);h.failCreate(false);await h.submit();assert.equal(h.chats.length,1);
  h.chats[0].kind='group';h.PC.chats[0].kind='group';await h.open(true);assert.equal(h.w.q('.pc-member-list input[value="one"]'),null);h.choose('three');await h.submit();assert.equal(h.calls.filter(c=>c.a==='add_members').length,1);assert(h.chats[0].members.includes('three'));
 }finally{h.close();}
 console.log('PASS: visible search filtering, accent/agency/whitespace matching, empty results, single-recipient DMs, group selection, save/open/reload, retry without duplicate, sidebar filter, add members, and recoverable server errors.');
})().catch(e=>{console.error(e);process.exitCode=1;});
