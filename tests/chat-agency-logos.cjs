const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const dom=new JSDOM('<div id="app"></div>',{url:'https://example.test',runScripts:'outside-only'}),w=dom.window;
w.q=s=>w.document.querySelector(s);w.qa=s=>[...w.document.querySelectorAll(s)];w.esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));w.S={profile:{id:'me',role:'admin',division:'vivid_life',active:true},tab:'live-chat',session:{}};
w.divisionLabel=x=>x;w.adminDivisionList=()=>['vivid_life'];w.money=x=>'$'+x;w.loadDashboard=w.loadAgentDashboard=async()=>{};w.dash=w.agentDashboardPage=()=>'';w.bindDashboard=w.bindAgentDashboard=()=>{};w.PortalNotifications={};w.scrollTo=()=>{};w.flash=()=>{};w.modal=h=>w.document.body.insertAdjacentHTML('beforeend','<div id="modal">'+h+'</div>');w.closeModal=()=>w.q('#modal')?.remove();w.api=async()=>[];
w.eval(['chat-media.js','live-chat.js','chat-social.js','portal-collaboration.js','chat-workspace.js'].map(f=>fs.readFileSync(f,'utf8')).join('\n')+'\nwindow.state={CHAT,PC,SOCIAL,CHAT_UI};startChat=async()=>{};pcMarkRead=async()=>{};pcList=async()=>{};markChatRead=async()=>{};');
const {CHAT,PC,SOCIAL,CHAT_UI}=w.state;CHAT.division='vivid_life';CHAT.scopes=['vivid_life'];CHAT.owner='me';PC.owner='me';
CHAT.rows=[{id:1,author_id:'other',author_name:'Other',kind:'message',body:'Morning team',created_at:'2026-11-05T14:00:00Z'},{id:2,author_id:'me',author_name:'Me',kind:'message',body:'Hello <img src=x>',created_at:'2026-11-05T14:05:00Z'}];
SOCIAL.meta={members:[{id:'me',name:'Me'},{id:'other',name:'Other'}],replies:[],reactions:[],pins:[{id:'pin',title:'Call guide'}]};SOCIAL.unread=[{division:'vivid_life',channel:'general',unread:2}];
PC.chats=[{id:'g',kind:'group',name:'Team <group>',members:['me','other'],owner_id:'me',unread:3,last_body:'Latest message',last_at:'2026-11-05T14:00:00Z'},{id:'d',kind:'direct',name:'Colleague',members:['me','other'],unread:0,last_body:'VIVID_MEDIA:truncated'}];
w.render=()=>{w.q('#app').innerHTML=w.chatPage();w.bindChat();};w.render();

(async()=>{try{
w.portalSessionEpoch=1;w.BASE='https://example.test';
const path='onyx_life/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222.png';
assert.equal(w.chatAgencyLogoUrl({id:'onyx_life',logo_path:'https://foreign.test/x'}),'');
assert.equal(w.chatAgencyLogoUrl({id:'vivid_life',logo_path:path}),'/assets/vivid-life-advisors.png');
CHAT.rows=[{id:19,kind:'deal',author_id:'other',author_name:'Agent',division:'onyx_life',created_at:'2026-11-05T14:00:00Z',deal:{annual_premium:1200}}];
w.q('#app').innerHTML=w.chatPage();w.api=async()=>[{id:'onyx_life',name:'Onyx Life',logo_path:path}];await w.chatPaintAgencyLogos();
const img=w.q('[data-chat-agency-logo] img');assert.ok(img);assert.match(img.src,/agency-logos\/onyx_life/);assert.equal(img.alt,'Onyx Life logo');img.onerror();assert.ok(img.parentNode.hidden);
w.S.profile.id='changed';w.q('#app').innerHTML=w.chatPage();w.api=async()=>{w.S.profile.id='changed-again';return [{id:'onyx_life',logo_path:path}]};await w.chatPaintAgencyLogos();assert.equal(w.q('[data-chat-agency-logo] img'),null);
console.log('PASS: agency-specific logo, path validation, mismatch rejection, broken image fallback and late-account response isolation');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
