'use strict';
const {database}=require('./dialer-full');
// These grants expired before any browser call was bound. Never infer that an
// uncertain Power Dialer leg or a provider-bound call was unused.
async function cleanup(){
 const now=new Date(),cutoff=new Date(now.getTime()-120000).toISOString();
 const rows=await database('dialer_calls?'+new URLSearchParams({call_kind:'in.(lead,manual)',finished:'eq.false',parent_sid:'is.null',child_sid:'is.null',duration_seconds:'eq.0',expires_at:'lt.'+cutoff,select:'id'}),{finished:true,call_status:'canceled',finished_at:now.toISOString()},'PATCH');
 return {unusedReservationsClosed:rows.length};
}
module.exports={cleanup};
