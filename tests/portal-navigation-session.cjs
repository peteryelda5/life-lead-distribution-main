const fs=require('fs'),vm=require('vm'),assert=require('assert');
const path=require('path'),root=path.resolve(__dirname,'..');
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
function line(name){const m=html.match(new RegExp('(?:async )?function '+name+'\\([^\\n]*'));assert(m,name);return m[0]}
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
async function testNavigation(){
 const wait=deferred(),S={profile:{id:'a'},session:{},tab:'dashboard',filter:'old',selected:new Set(['lead'])};let renders=0,loads=0;
 const surface=()=>({isConnected:true,setAttribute(){},removeAttribute(){},insertAdjacentHTML(){},remove(){}});
 const wrap=surface(),buttons=[{...surface(),dataset:{tab:'leads'}},{...surface(),dataset:{tab:'agents'}}];
 const c={S,portalSessionEpoch:0,q:s=>s==='.wrap'?wrap:surface(),qa:()=>buttons,render:()=>renders++,flash:()=>{},loadTabData:()=>{loads++;return wait.promise}};
 vm.createContext(c);vm.runInContext(html.match(/let portalNavigationBusy=false;[\s\S]*?(?=function bindShell)/)[0],c);
 const first=c.navigatePortalTab('leads');assert.equal(S.tab,'leads');assert(wrap.inert);assert(buttons.every(b=>b.disabled));await c.navigatePortalTab('agents');assert.equal(loads,1);assert.equal(S.tab,'leads');wait.resolve();await first;assert.equal(renders,1);assert(!wrap.inert);assert(buttons.every(b=>!b.disabled));
 const failed=deferred();c.loadTabData=()=>failed.promise;let error='';c.flash=m=>error=m;const task=c.navigatePortalTab('agents');failed.reject(new Error('offline'));await task;assert.equal(S.tab,'leads');assert.equal(error,'offline');
}
async function testRefresh(){
 const pending=deferred(),old={refresh_token:'old'},S={session:old,profile:{id:'a'}};let saves=0;
 const c={S,refreshPromise:null,raw:()=>pending.promise,saveSession:x=>{saves++;S.session=x},currentAal:()=> 'aal2',render(){}};vm.createContext(c);vm.runInContext(line('refreshToken'),c);const task=c.refreshToken();S.session=null;S.profile=null;pending.resolve({access_token:'new',refresh_token:'new'});assert.equal(await task,false);assert.equal(S.session,null);assert.equal(saves,0);
 const fail=deferred();S.session=old;c.raw=()=>fail.promise;const second=c.refreshToken();const newUser={refresh_token:'other'};S.session=newUser;fail.reject(Object.assign(new Error('expired'),{status:401}));await second;assert.strictEqual(S.session,newUser);
}
async function testRawGuard(){
 const gate=deferred(),S={session:{access_token:'old'}},c={S,KEY:'public',BASE:'https://example.test',portalSessionEpoch:0,portalFetch:()=>gate.promise};
 vm.createContext(c);vm.runInContext(line('raw'),c);const task=c.raw('/rest/v1/leads');c.portalSessionEpoch++;gate.resolve({ok:true,text:async()=> '[]'});await assert.rejects(task,e=>e.status===409);
}
function testEpoch(){const S={session:{user:{id:'a'}},profile:{id:'a'}};const c={S,portalSessionEpoch:0,jwtPayload:()=>({sub:S.session?.user?.id}),localStorage:{setItem(){},removeItem(){}}};vm.createContext(c);vm.runInContext(line('saveSession'),c);c.saveSession({user:{id:'a'},access_token:'refreshed'});assert.equal(c.portalSessionEpoch,0);c.saveSession(null);assert.equal(c.portalSessionEpoch,1);c.saveSession({user:{id:'b'}});assert.equal(c.portalSessionEpoch,2);}
function testFeedback(){
 const tasks=[],S={profile:{id:'a'},msg:'first',err:''};let replacements=0;
 const c={S,feedbackVersion:0,setTimeout:f=>tasks.push(f),q:()=>({replaceChildren:()=>replacements++})};
 vm.createContext(c);vm.runInContext(line('scheduleFeedbackClear'),c);c.scheduleFeedbackClear(3000);S.msg='second';c.scheduleFeedbackClear(3000);tasks[0]();assert.equal(S.msg,'second');tasks[1]();assert.equal(S.msg,'');assert.equal(replacements,1);
}
function testCsv(){const c={window:{},esc:String};vm.createContext(c);vm.runInContext(fs.readFileSync(path.join(root,'book-of-business.js'),'utf8'),c);assert.equal(c.window.PORTAL_CRM_CSV.cell('a"b'),'"a""b"');assert.equal(c.window.PORTAL_CRM_CSV.cell('=1+1'),'"\'=1+1"');const result=c.window.PORTAL_CRM_CSV.rows([{client_name:'Test',agent_name:'Agent'}]);assert(result.includes('Closing agent name'));assert(result.includes('Agent'));}
(async()=>{await testNavigation();await testRefresh();await testRawGuard();testEpoch();testFeedback();testCsv();console.log('PASS: serialized tab switching; failed navigation recovery; logout/refresh race; stale account response rejection; notification dismissal; CSV escaping and closing-agent column');})().catch(e=>{console.error(e);process.exitCode=1});
