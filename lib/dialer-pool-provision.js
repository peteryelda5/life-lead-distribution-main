'use strict';
const {database,config,twilio,ORIGIN}=require('./dialer-full');
const PHONE=/^\+1[2-9]\d{2}[2-9]\d{6}$/;
const tag=n=>'vivid-pool-'+n.purchase_key;
async function rentalPrice(){
 const c=config(),r=await fetch('https://pricing.twilio.com/v1/PhoneNumbers/Countries/US',{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw Error('Number rental price could not be verified');const d=await r.json(),prices=(d.phone_number_prices||[]).filter(x=>x.number_type==='local');
 if(d.country!=='United States'&&d.iso_country!=='US'||String(d.price_unit).toUpperCase()!=='USD'||prices.length!==1||!(Number(prices[0].current_price)>0)||Number(prices[0].current_price)>1.15)throw Error('Number rental exceeds the approved $1.15 monthly limit');
}
async function provision(pool,n){
 const path='dialer_pool_numbers?pool_id=eq.'+pool.id+'&slot=eq.'+n.slot;
 const finish=async found=>{
  if(found.account_sid!==pool.provider_sid||found.phone_number!==n.phone||found.friendly_name!==tag(n)||!/^PN[a-f0-9]{32}$/i.test(found.sid||''))throw Error('Number ownership mismatch');
  if(found.voice_url!==ORIGIN+'/api/dialer/pool-incoming'||found.voice_method!=='POST')throw Error('Callback configuration requires review');
  await database(path,{provider_number_sid:found.sid,state:'active',provision_error:null},'PATCH');
 };
 if(n.state==='purchasing'){
  const d=await twilio('IncomingPhoneNumbers.json?'+new URLSearchParams({PhoneNumber:n.phone,PageSize:'100'}));
  const matches=(d.incoming_phone_numbers||[]).filter(x=>x.phone_number===n.phone&&x.friendly_name===tag(n));
  if(d.next_page_uri||matches.length!==1)throw Error('Purchase response uncertain; automatic re-purchase blocked');
  await finish(matches[0]);return;
 }
 if(n.state!=='planned'||!/^\d{3}$/.test(n.requested_area||''))throw Error('Invalid number plan');
 const d=await twilio('AvailablePhoneNumbers/US/Local.json?'+new URLSearchParams({AreaCode:n.requested_area,VoiceEnabled:'true',PageSize:'10'}));
 const found=(d.available_phone_numbers||[]).find(x=>PHONE.test(x.phone_number)&&x.phone_number.slice(2,5)===n.requested_area&&x.capabilities?.voice===true);
 if(!found)throw Error('No voice number available in requested area code');
 const claimed=await database(path+'&state=eq.planned',{phone:found.phone_number,state:'purchasing',attempted_at:new Date().toISOString(),provision_error:null},'PATCH');
 if(claimed.length!==1)return;n=claimed[0];
 // At most one POST per slot. Uncertain responses are reconciled by exact phone/tag.
 const bought=await twilio('IncomingPhoneNumbers.json',{PhoneNumber:n.phone,FriendlyName:tag(n),VoiceUrl:ORIGIN+'/api/dialer/pool-incoming',VoiceMethod:'POST'});
 await finish(bought);
}
async function maintenance(){
 const pools=await database('dialer_caller_pools?provision_authorized=eq.true&select=*');let active=0,errors=0,checked=0;
 for(const pool of pools){
  if(pool.provider_sid!==config().TWILIO_ACCOUNT_SID){errors++;continue;}
  const rows=await database('dialer_pool_numbers?'+new URLSearchParams({pool_id:'eq.'+pool.id,state:'in.(planned,purchasing)',or:'(attempted_at.is.null,attempted_at.lt.'+new Date(Date.now()-300000).toISOString()+')',order:'slot.asc',limit:'4'}));
  if(rows.some(n=>n.state==='planned'))await rentalPrice();
  for(const n of rows){checked++;try{await provision(pool,n);active++;}catch(e){errors++;await database('dialer_pool_numbers?pool_id=eq.'+pool.id+'&slot=eq.'+n.slot,{provision_error:e.providerCode?'Provider error '+e.providerCode:String(e.message).slice(0,160),attempted_at:new Date().toISOString()},'PATCH');}}
 }
 return {checked,active,errors};
}
module.exports={maintenance,provision,rentalPrice};
