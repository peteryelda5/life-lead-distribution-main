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
w.portalSessionEpoch=1;
PC.group=null;CHAT.rows=[{id:12,author_id:'other',author_name:'Agent',kind:'deal',division:'vivid_life',created_at:'2026-11-05T14:00:00Z',deal:{annual_premium:1200,monthly_premium:100,carrier:'Carrier <test>',policy_type:'Whole life'}}];w.render();
assert.match(w.q('.ui-deal-card').textContent,/NEW DEAL SUBMITTED/);assert.equal(w.q('.ui-deal-card test'),null);
w.api=async()=>({agent_name:'Agent',agency:'vivid_life',annual_premium:1200,monthly_premium:100,carrier:'Carrier',product:'Whole life',policy_id:null});
await w.q('[data-view-chat-deal]').onclick();assert.ok(w.q('.ui-deal-summary'));assert.match(w.q('.ui-deal-summary').textContent,/Client and commission details are not included/);w.closeModal();
let prepared=null,route=null;w.bobPreparePolicyView=id=>prepared=id;w.navigatePortalTab=async tab=>{route=tab;w.S.tab=tab};w.api=async()=>({policy_id:'policy'});await w.q('[data-view-chat-deal]').onclick();assert.equal(prepared,'policy');assert.equal(route,'book-business');assert.equal(w.q('.ui-deal-summary'),null);
w.api=async()=>{throw Error('Unavailable')};await w.q('[data-view-chat-deal]').onclick();assert.equal(w.q('.ui-deal-error').textContent,'Unavailable');assert.equal(w.q('[data-view-chat-deal]').disabled,false);
w.api=async()=>{w.S.profile.id='changed';return {policy_id:'foreign'}};prepared=null;await w.q('[data-view-chat-deal]').onclick();assert.equal(prepared,null);
assert.doesNotMatch(w.chatDealCardHtml({deal:{withdrawn:true}}),/data-view-chat-deal/);
console.log('PASS: escaped deal card, safe summary, authorized routing, retry errors, account-switch isolation and removed deals');
}finally{dom.window.close()}})().catch(e=>{console.error(e);process.exitCode=1});
