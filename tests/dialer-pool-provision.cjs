'use strict';
const assert=require('node:assert/strict');
const account='AC'+'a'.repeat(32),pool={id:'pool',provider_sid:account};
let row,posts=0,uncertain=false,owned=[],rental='1.15',claimLost=false;
const origin='https://www.lldportal.com';
const reset=()=>{row={pool_id:'pool',slot:1,state:'planned',requested_area:'202',purchase_key:'fixture'};posts=0;uncertain=false;owned=[];claimLost=false;};
require.cache[require.resolve('../lib/dialer-full')]={exports:{ORIGIN:origin,config:()=>({TWILIO_ACCOUNT_SID:account,TWILIO_AUTH_TOKEN:'fixture'}),database:async(path,body)=>{
 if(path.includes('state=eq.planned')&&claimLost)return[];
 Object.assign(row,body);return[{...row}];
},twilio:async(path,body)=>{
 if(path.startsWith('AvailablePhoneNumbers'))return{available_phone_numbers:[{phone_number:'+12025550120',capabilities:{voice:true}}]};
 if(body){posts++;const n={account_sid:account,phone_number:body.PhoneNumber,friendly_name:body.FriendlyName,sid:'PN'+'a'.repeat(32),voice_url:body.VoiceUrl,voice_method:body.VoiceMethod};owned=[n];if(uncertain)throw Error('timeout');return n;}
 return{incoming_phone_numbers:owned,next_page_uri:null};
}}};
global.fetch=async url=>{assert.equal(url,'https://pricing.twilio.com/v1/PhoneNumbers/Countries/US');return{ok:true,json:async()=>({iso_country:'US',price_unit:'USD',phone_number_prices:[{number_type:'local',current_price:rental}]})};};
const app=require('../lib/dialer-pool-provision');
(async()=>{
 await app.rentalPrice();rental='1.16';await assert.rejects(app.rentalPrice(),/approved/);rental='1.15';
 reset();await app.provision(pool,row);assert.equal(posts,1);assert.equal(row.state,'active');assert.equal(owned[0].voice_url,origin+'/api/dialer/pool-incoming');
 reset();uncertain=true;await assert.rejects(app.provision(pool,row),/timeout/);assert.equal(row.state,'purchasing');uncertain=false;await app.provision(pool,row);assert.equal(posts,1);assert.equal(row.state,'active');
 reset();row.state='purchasing';row.phone='+12025550120';await assert.rejects(app.provision(pool,row),/re-purchase blocked/);assert.equal(posts,0);
 owned=[{phone_number:row.phone,friendly_name:'someone-else'}];await assert.rejects(app.provision(pool,row),/re-purchase blocked/);assert.equal(posts,0);
 reset();claimLost=true;await app.provision(pool,row);assert.equal(posts,0);
 console.log('PASS: exact monthly price cap, callback configuration, purchase once, uncertain-response reconciliation, foreign number rejection and concurrent claim loss.');
})().catch(e=>{console.error(e);process.exitCode=1;});
