const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('index.html','utf8'),source=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(x=>x.startsWith('const BASE='));
const ctx=vm.createContext({URLSearchParams,Intl,Set,Map,Date,Number,String,JSON,localStorage:{getItem:()=>null},window:{supabase:{createClient:()=>({})}},document:{getElementById:()=>({}),querySelector:()=>({}),querySelectorAll:()=>[],addEventListener:()=>{}},setInterval:()=>{}});
vm.runInContext(fs.readFileSync('team-leaders.js','utf8'),ctx);vm.runInContext(source.slice(0,source.lastIndexOf('(async()=>{if(S.session)')),ctx);
vm.runInContext(`S.profile={id:'a',role:'admin',active:true,is_super_admin:true,division:'vivid_life',full_name:'Master'};S.agents=[{id:'b',full_name:'Leader',is_team_leader:true,division:'vivid_life',active:true}];`,ctx);
assert(vm.runInContext('agentPage()',ctx).includes('Team settings'));
vm.runInContext(`S.profile={id:'a',role:'agent',is_team_leader:true,active:true,division:'vivid_life',full_name:'Leader'};currentAal=()=> 'aal2';`,ctx);
assert(vm.runInContext("shell('','agent')",ctx).includes('My uploads'));
assert(vm.runInContext("canAddLeads('vivid_life')",ctx));assert(!vm.runInContext("canAddLeads('legacy_life')",ctx));
assert(vm.runInContext('myUploads()',ctx).includes('Import CSV'));
vm.runInContext('S.profile.is_team_leader=false',ctx);assert(!vm.runInContext("shell('','agent')",ctx).includes('My uploads'));assert(!vm.runInContext("canAddLeads('vivid_life')",ctx));
console.log('PASS: master team controls, team-leader upload tab, ordinary-agent restrictions, same-division uploads');

vm.runInContext("S.profile={id:'legacy-admin',role:'admin',active:true,is_super_admin:false,division:'legacy_life'};",ctx);
assert(vm.runInContext("canManageTeam({division:'legacy_life',archived:false})",ctx));
assert(!vm.runInContext("canManageTeam({division:'vivid_life',archived:false})",ctx));
assert(!vm.runInContext("canManageTeam({division:'legacy_life',archived:true})",ctx));
vm.runInContext('S.profile.active=false',ctx);assert(!vm.runInContext("canManageTeam({division:'legacy_life'})",ctx));
console.log('PASS: division-scoped team controls, archived target and inactive admin blocked');
