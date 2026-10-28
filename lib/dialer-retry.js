'use strict';
const {database}=require('./dialer-full');
const COOL_DOWN=30*60*1000,DAILY_LIMIT=5;
function decision(calls,now=Date.now()){
 const attempts=calls.filter(c=>c.parent_sid);
 const today=attempts.filter(c=>Date.parse(c.created_at)>now-86400000);
 if(today.length>=DAILY_LIMIT)return 'Daily attempt limit reached. Try after the rolling 24-hour window.';
 const latest=Math.max(0,...today.map(c=>Date.parse(c.created_at)));
 if(latest+COOL_DOWN>now)return 'Retry available after '+new Date(latest+COOL_DOWN).toISOString()+'.';
 return null;
}
async function check(user,batch,phones){
 if(!phones.length)return new Map();
 const prior=await database('dialer_parallel_legs?'+new URLSearchParams({session_id:'eq.'+batch,select:'id'}));const own=new Set(prior.map(r=>r.id));
 const rows=await database('dialer_calls?'+new URLSearchParams({user_id:'eq.'+user,livemode:'eq.true',phone:'in.('+phones.join(',')+')',created_at:'gt.'+new Date(Date.now()-86400000).toISOString(),parent_sid:'not.is.null',select:'id,phone,parent_sid,call_status,duration_seconds,created_at',order:'created_at.desc',limit:'200'}));
 return new Map(phones.map(phone=>[phone,rows.length>=200?'Call history requires review before another attempt.':decision(rows.filter(r=>r.phone===phone&&!own.has(r.id)))]));
}
module.exports={check,decision};
