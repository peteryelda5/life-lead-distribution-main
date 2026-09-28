const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8'),source=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(x=>x.startsWith('const BASE='));
const ctx=vm.createContext({URLSearchParams,Intl,Set,Map,Date,Number,String,JSON,localStorage:{getItem:()=>null},window:{supabase:{createClient:()=>({})}},document:{getElementById:()=>({}),querySelector:()=>({}),querySelectorAll:()=>[],addEventListener:()=>{}},setInterval:()=>{}});
vm.runInContext(fs.readFileSync('team-leaders.js','utf8'),ctx);vm.runInContext(source.slice(0,source.lastIndexOf('(async()=>{if(S.session)')),ctx);
vm.runInContext(`S.divisions=['owner','vivid_life','legacy_life'].map(id=>({id}));S.profile={id:'a',role:'admin',active:true,is_super_admin:true,division:'vivid_life',full_name:'Master'};S.agents=[{id:'b',full_name:'Leader',is_team_leader:true,division:'vivid_life',active:true}];`,ctx);

vm.runInContext(fs.readFileSync('divisions.js','utf8'),ctx);
let page=vm.runInContext('leadPage()',ctx);
assert(page.includes('sendDivisionPick'));assert(!page.includes('id="pick"'));assert(!page.includes('id="assign"'));
vm.runInContext("S.profile.is_super_admin=false;S.adminDivisions=['vivid_life']",ctx);
page=vm.runInContext('leadPage()',ctx);assert(page.includes('id="pick"'));assert(page.includes('id="assign"'));assert(!page.includes('sendDivisionPick'));
vm.runInContext("S.profile.is_super_admin=true;S.adminDivisions=['owner','vivid_life','legacy_life'];S.divisionFilter='legacy_life'",ctx);
page=vm.runInContext('leadPage()',ctx);assert(page.includes('Legacy leads stay in Legacy'));assert(!page.includes('sendDivisionPick'));
console.log('PASS Master division controls, admin assignments, Legacy boundary');
