'use strict';
// Recovery-only reads. Every database/storage call uses the caller's verified JWT.
const {onboardingProgress,MASTER}=require('./docusign');
const {failure}=require('./dialer-full');
const BASE='https://ebvubpcevljgjuhiraqn.supabase.co';
const KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVidnVicGNldmxqZ2p1aGlyYXFuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2NjE0MTUsImV4cCI6MjEwNzIzNzQxNX0.uTm9Bjh_844-XNAjMNDf9K84E-UASqM__Ecm9Iuxnk4';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const ACTIONS=new Set(['status','overview','agreements','download','refresh','refreshAgreement']);
function publicAgreement(a){return a?{id:a.id,status:a.status,waiting_on:a.waiting_on||null,envelope_id:a.document_id,signing_method:'email',pdf_path:a.pdf_path,certificate_path:null,provider:'SignWell',signer_email:a.signer_email}:null;}
async function request(auth,path,body){const r=await fetch(BASE+path,{method:'POST',headers:{apikey:KEY,Authorization:auth,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});let d;try{d=await r.json();}catch{throw failure(502,'Recovery service returned an invalid response.');}if(!r.ok)throw failure(r.status===401?401:r.status===403?403:503,r.status===401?'Sign in to the recovery portal again.':d.message||'Unable to load recovered onboarding records.');return d;}
async function action(req){
 const b=req.body,auth=req.headers.authorization||'';
 if(!ACTIONS.has(b.action))throw failure(403,'Recovery test: signing emails and configuration changes are disabled.');
 if(!/^Bearer [A-Za-z0-9_.-]+$/.test(auth))throw failure(401,'Sign in to the recovery portal first.');
 if(b.id!==undefined&&!UUID.test(b.id))throw failure(400,'Invalid agreement.');
 const all=b.action==='overview'||b.action==='agreements'||b.id!==undefined;
 const d=await request(auth,'/rest/v1/rpc/recovery_onboarding_snapshot',{p_all:all});
 const mine=d.agreements.find(a=>a.user_id===d.user_id&&a.environment==='live'&&!a.superseded)||null;
 if(b.action==='status')return{provider:'SignWell',environment:'live',connected:false,masterLiveOnly:false,signingReady:false,agreement:publicAgreement(mine),resources:d.resources.find(r=>r.user_id===d.user_id)||{}};
 if(b.action==='overview'){
  const map=rows=>new Map(rows.map(r=>[r.user_id,r]));const checks=map(d.checks),receipts=map(d.receipts),resources=map(d.resources),agreements=map(d.agreements.filter(a=>a.environment==='live'&&!a.superseded)),agencies=new Map(d.agencies.map(a=>[a.id,a.name]));
  return{environment:'live',rows:d.profiles.filter(p=>p.id!==MASTER).map(p=>onboardingProgress({...p,division:agencies.get(p.division)||p.division||'Unassigned'},checks.get(p.id),receipts.get(p.id),resources.get(p.id),publicAgreement(agreements.get(p.id))))};
 }
 if(b.action==='agreements')return{agreements:[...d.agreements.map(a=>({id:a.id,signer_name:a.signer_name,status:a.status,pdf_path:a.pdf_path,provider:'SignWell'})),...d.legacy.map(a=>({id:a.id,signer_name:a.signer_name,status:a.status,pdf_path:a.pdf_path,certificate_path:a.certificate_path,provider:'DocuSign'}))]};
 const a=b.id?(d.agreements.find(a=>a.id===b.id)||d.legacy.find(a=>a.id===b.id)):mine;
 if(b.action==='refresh'||b.action==='refreshAgreement')return{agreement:a?.document_id?publicAgreement(a):a?{id:a.id,status:a.status,envelope_id:a.envelope_id,pdf_path:a.pdf_path,certificate_path:a.certificate_path}:null};
 if(!['agreement','certificate'].includes(b.kind))throw failure(400,'Invalid download.');
 const path=b.kind==='agreement'?a?.pdf_path:a?.certificate_path;
 if(!path||a.status!=='completed')throw failure(404,'Completed document is not available.');
 const signed=await request(auth,'/storage/v1/object/sign/onboarding-agreements/'+path.split('/').map(encodeURIComponent).join('/'),{expiresIn:60});
 const relative=signed.signedURL||signed.signedUrl;if(typeof relative!=='string'||!relative.startsWith('/object/sign/'))throw failure(502,'Invalid document download URL.');
 return{url:BASE+'/storage/v1'+relative};
}
module.exports={action};
