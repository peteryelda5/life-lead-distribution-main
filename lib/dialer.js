'use strict';
const {createHmac, timingSafeEqual, randomUUID} = require('node:crypto');
const MASTER = '8139e230-055d-4247-8133-684ed817b4fa';
const IDENTITY = 'vivid_master_test';
const BASE = 'https://yfuuigykpihoetgaefmu.supabase.co';
const KEY = 'sb_publishable_6O3XhhYJrjhN_5U1cFxz2g_fYI-3uE6';
const VOICE_URL = 'https://www.lldportal.com/api/dialer/voice';
const now = () => Math.floor(Date.now()/1000);
const failure = (status, message) => Object.assign(new Error(message), {status});
function config() {
  const names = ['TWILIO_ACCOUNT_SID','TWILIO_AUTH_TOKEN','TWILIO_PHONE_NUMBER','TWILIO_API_KEY_SID','TWILIO_API_KEY_SECRET','TWILIO_TWIML_APP_SID','TWILIO_TEST_PHONE_NUMBER'];
  const c = Object.fromEntries(names.map(n=>[n,process.env[n]]));
  const missing = names.filter(n=>!c[n]);
  if(missing.length) throw failure(503,'Setup required: '+missing.join(', '));
  for(const [name,prefix] of [['TWILIO_ACCOUNT_SID','AC'],['TWILIO_API_KEY_SID','SK'],['TWILIO_TWIML_APP_SID','AP']]) {
    if(!new RegExp('^'+prefix+'[a-fA-F0-9]{32}$').test(c[name])) throw failure(503,'Check '+name+' in Vercel.');
  }
  for(const name of ['TWILIO_PHONE_NUMBER','TWILIO_TEST_PHONE_NUMBER']) {
    if(!/^\+1[2-9]\d{9}$/.test(c[name])) throw failure(503,name+' must be a US number in +1 format.');
  }
  if(c.TWILIO_PHONE_NUMBER===c.TWILIO_TEST_PHONE_NUMBER) throw failure(503,'Use your personal phone as the test destination, not the Twilio number.');
  return c;
}
function equal(a,b) {
  const x=Buffer.from(String(a)),y=Buffer.from(String(b));
  return x.length===y.length && timingSafeEqual(x,y);
}
function signed(payload,secret,header={alg:'HS256',typ:'JWT'}) {
  const body=[header,payload].map(x=>Buffer.from(JSON.stringify(x)).toString('base64url')).join('.');
  return body+'.'+createHmac('sha256',secret).update(body).digest('base64url');
}
function verifyGrant(token,c) {
  if(typeof token!=='string'||token.length>2048) throw failure(403,'Invalid call authorization.');
  const parts=token.split('.');
  if(parts.length!==3 || !equal(parts[2],createHmac('sha256',c.TWILIO_API_KEY_SECRET).update(parts.slice(0,2).join('.')).digest('base64url'))) throw failure(403,'Invalid call authorization.');
  let h,p;try{h=JSON.parse(Buffer.from(parts[0],'base64url'));p=JSON.parse(Buffer.from(parts[1],'base64url'));}catch{throw failure(403,'Invalid call authorization.');}
  if(h.alg!=='HS256'||h.typ!=='JWT'||p.aud!=='vivid-dialer-test'||p.sub!==MASTER||p.identity!==IDENTITY||p.to!==c.TWILIO_TEST_PHONE_NUMBER||!Number.isInteger(p.exp)||p.exp<=now()||p.exp>now()+90) throw failure(403,'Expired or invalid call authorization.');
  return p;
}
async function master(req) {
  const auth=req.headers.authorization||'';
  if(!/^Bearer [A-Za-z0-9_.-]+$/.test(auth)) throw failure(401,'Sign in to the portal first.');
  const token=auth.slice(7);
  const headers={apikey:KEY,Authorization:auth};
  const response=await fetch(BASE+'/auth/v1/user',{headers,signal:AbortSignal.timeout(8000)});
  if(!response.ok) throw failure(401,'Your portal session expired. Sign in again.');
  const user=await response.json();
  if(user.id!==MASTER) throw failure(403,'This test is available only to the Master account.');
  let claims;try{claims=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));}catch{throw failure(401,'Invalid session.');}
  if(claims.sub!==user.id||claims.aal!=='aal2'||claims.exp<=now()) throw failure(403,'Complete two-step verification in the portal first.');
  const profile=await fetch(BASE+'/rest/v1/profiles?id=eq.'+MASTER+'&select=id,role,active,is_super_admin,archived',{headers,signal:AbortSignal.timeout(8000)});
  if(!profile.ok) throw failure(403,'Could not verify Master access.');
  const rows=await profile.json();
  if(rows.length!==1||rows[0].role!=='admin'||rows[0].active!==true||rows[0].is_super_admin!==true||rows[0].archived!==false) throw failure(403,'Master access is unavailable.');
}
function tokens(c) {
  const t=now();
  return {
    token:signed({jti:c.TWILIO_API_KEY_SID+'-'+randomUUID(),iss:c.TWILIO_API_KEY_SID,sub:c.TWILIO_ACCOUNT_SID,iat:t,nbf:t-5,exp:t+300,grants:{identity:IDENTITY,voice:{outgoing:{application_sid:c.TWILIO_TWIML_APP_SID},incoming:{allow:false}}}},c.TWILIO_API_KEY_SECRET,{alg:'HS256',typ:'JWT',cty:'twilio-fpa;v=1'}),
    callGrant:signed({aud:'vivid-dialer-test',sub:MASTER,identity:IDENTITY,to:c.TWILIO_TEST_PHONE_NUMBER,iat:t,exp:t+60},c.TWILIO_API_KEY_SECRET),
    callerId:c.TWILIO_PHONE_NUMBER,
    destination:c.TWILIO_TEST_PHONE_NUMBER
  };
}
function validWebhook(req,body,c) {
  if(req.url.split('?')[0]!=='/api/dialer/voice'||req.url.includes('?')) return false;
  const signature=req.headers['x-twilio-signature'];
  if(typeof signature!=='string') return false;
  let data=VOICE_URL;
  for(const k of Object.keys(body).sort()) {
    if(typeof body[k]!=='string') return false;
    data+=k+body[k];
  }
  return equal(signature,createHmac('sha1',c.TWILIO_AUTH_TOKEN).update(data).digest('base64'));
}
module.exports={config,master,tokens,verifyGrant,validWebhook,VOICE_URL,IDENTITY,MASTER,failure};
