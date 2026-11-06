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
try{
 assert.ok(w.q('.chat-workspace'));assert.ok(w.q('#uiChatDetails'));assert.equal(w.qa('.ui-own').length,1);assert.equal(w.qa('.ui-chat-date').length,1);assert.equal(w.q('.chat-message-text img'),null);assert.match(w.q('#uiPinnedBar').textContent,/Call guide/);assert.match(w.q('[data-pc-room="d"]').textContent,/Photo or GIF/);
 w.q('[data-ui-unread="true"]').click();assert.ok(w.q('[data-pc-room="d"]').hidden);assert.equal(w.q('[data-pc-room="g"]').hidden,false);
 w.q('#pcChatSearch').value='no matches';w.q('#pcChatSearch').dispatchEvent(new w.Event('input'));assert.equal(w.q('#uiChatEmpty').hidden,false);
 w.q('#pcChatSearch').value='Team';w.q('#pcChatSearch').dispatchEvent(new w.Event('input'));w.render();assert.equal(w.q('#pcChatSearch').value,'Team');
 w.q('#uiFindMessages').click();w.q('#uiMessageQuery').value='Morning';w.q('#uiMessageQuery').dispatchEvent(new w.Event('input'));assert.equal(w.qa('#chatMessages .chat-message:not([hidden])').length,1);w.q('#uiCloseMessageSearch').click();assert.equal(w.qa('#chatMessages .chat-message:not([hidden])').length,2);
 w.q('#uiViewMembers').click();assert.match(w.q('#modal').textContent,/Other/);w.q('#uiMembersClose').click();
 w.q('#uiBackChats').click();assert.ok(w.q('.ui-show-list'));w.q('#uiToggleDetails').click();assert.ok(w.q('.ui-show-details'));w.q('[data-ui-close-details]').click();assert.equal(w.q('.ui-show-details'),null);
 PC.group='g';PC.rows=[{id:3,author_id:'me',author_name:'Me',body:'Private text',created_at:'2026-11-05T14:05:00Z'}];w.render();assert.equal(w.q('[data-ui-pins]'),null,'channel pins never leak into private group');assert.match(w.q('.ui-own').textContent,/Private text/);assert.equal(w.q('#chatSlash').hidden,true);
 console.log('PASS: real conversation previews, own-message bubbles, dates, escaped text, unread/search filters, loaded-message search, member details, mobile navigation and private/channel separation');
}finally{dom.window.close()}
