'use strict';
const {failure}=require('./dialer-full');
// Twilio Basic Lookup (no Fields parameter) validates numbering-plan formatting.
// It does not prove that a number is in service or that its owner will answer.
async function validate(phone,c){
 if(!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(phone||''))throw failure(400,'This lead needs a valid US phone number. Correct the number or choose another lead.');
 const r=await fetch('https://lookups.twilio.com/v2/PhoneNumbers/'+encodeURIComponent(phone),{headers:{Authorization:'Basic '+Buffer.from(c.TWILIO_ACCOUNT_SID+':'+c.TWILIO_AUTH_TOKEN).toString('base64')},signal:AbortSignal.timeout(8000)});
 if(!r.ok)throw failure(503,'Number verification is temporarily unavailable. No call was started; please retry.');
 const d=await r.json();if(d.valid!==true||d.country_code!=='US'||d.phone_number!==phone)throw failure(400,'The provider does not recognize this as a valid US number. Correct the number or choose another lead.');
 return phone;
}
module.exports={validate};
