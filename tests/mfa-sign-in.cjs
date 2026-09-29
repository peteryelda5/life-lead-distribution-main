const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
let factors=[{id:'verified-factor',status:'verified'}],lastRequest='';
const client={auth:{setSession:async()=>({data:{session:null}}),mfa:{listFactors:async()=>({data:{totp:factors}})}}};
const context=vm.createContext({URLSearchParams,Intl,Set,Map,Date,Number,String,JSON,atob,localStorage:{getItem:()=>null,setItem:()=>{},removeItem:()=>{}},window:{supabase:{createClient:()=>client},LLDStartup:{ready:()=>{}}},document:{getElementById:()=>({}),querySelector:()=>null,querySelectorAll:()=>[],addEventListener:()=>{}},setInterval:()=>{}});
const src=[...fs.readFileSync('index.html','utf8').matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).find(x=>x.startsWith('const BASE='));
vm.runInContext(src.slice(0,src.lastIndexOf('(async()=>{if(S.session)')),context);
vm.runInContext("S.session={access_token:'fixture',refresh_token:'fixture'};resetChatSocial=stopChat=stopLeaderboard=stopRequestBadge=()=>{};saveSession=()=>{};currentAal=()=> 'aal1';render=()=>{};loadCore=()=>{throw Error('Lead data accessed before MFA')};",context);
vm.runInContext("api=async(path,opt)=>{globalThis.lastRequest=path;return {id:'agent-id',full_name:'Fixture Agent',role:'agent',active:true,division:'owner'}};",context);
(async()=>{await vm.runInContext('load()',context);assert.equal(vm.runInContext('lastRequest',context),'/rest/v1/rpc/account_bootstrap');assert.equal(vm.runInContext('S.profile.full_name',context),'Fixture Agent');assert.equal(vm.runInContext('S.mfaMode',context),'challenge');assert.equal(vm.runInContext('S.profile.active',context),true);console.log('PASS agent profile bootstrap leads to MFA challenge without loading lead data');})().catch(e=>{console.error(e);process.exit(1)});
