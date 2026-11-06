const fs=require('node:fs'),assert=require('node:assert/strict'),{JSDOM}=require('jsdom');
const dom=new JSDOM('<main></main>',{runScripts:'outside-only'}),w=dom.window;
w.S={pendingRequestCount:2};w.q=s=>w.document.querySelector(s);w.qa=s=>[...w.document.querySelectorAll(s)];w.canReceiveLeadRequests=()=>true;w.dashboardIcon=()=>'';
for(const [file,name] of [['dashboard.js','dashboardLeadRequestsHtml'],['team-leaders.js','paintRequestBadge']])w.eval(fs.readFileSync(file,'utf8').split('\n').find(s=>s.startsWith('function '+name+'(')));
w.q('main').innerHTML=w.dashboardLeadRequestsHtml();assert.ok(w.q('.db-pending'));
w.S.pendingRequestCount=0;w.paintRequestBadge();assert.equal(w.q('.db-pending'),null);assert.equal(w.q('#dashboardRequestText').textContent,'0 pending requests');
w.S.pendingRequestCount=1;w.paintRequestBadge();assert.ok(w.q('.db-pending'));assert.equal(w.q('#dashboardRequestText').textContent,'1 pending request');
w.canReceiveLeadRequests=()=>false;w.paintRequestBadge();assert.equal(w.q('.db-pending'),null);assert.equal(w.q('#dashboardRequestCount').textContent,'0');
dom.window.close();console.log('PASS: initial pending highlight, live zero/positive transitions, singular text and role reset');
