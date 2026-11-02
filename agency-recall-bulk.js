/* Large recalls use a server-held preview and resumable, idempotent steps. */
function showAgencyRecallBulk(initial,agency){
 const user=S.profile?.id,epoch=portalSessionEpoch;
 if(!canRecallAgencyLeads(agency.id))return;
 closeModal();modal('<section id="recallBulk" class="stack"></section>');
 const root=q('#modal'),box=root.querySelector('.modalbox'),area=q('#recallBulk');
 root.classList.add('agency-recall-modal');box.setAttribute('role','dialog');box.setAttribute('aria-modal','true');box.setAttribute('aria-labelledby','recallBulkTitle');
 let job=initial,busy=false,pause=false;
 const valid=()=>root.isConnected&&S.profile?.id===user&&portalSessionEpoch===epoch&&canRecallAgencyLeads(agency.id);
 const find=s=>root.querySelector(s),number=n=>Number(n||0).toLocaleString();
 const complete=()=>!!job.finished_at||job.processed>=job.total;
 const close=()=>{if(busy){pause=true;find('#recallBulkMessage').textContent='Pausing after the current group finishes…';return}find('#recallBulkClose').onclick()};
 function draw(){
  const started=!!job.started_at,done=complete();
  area.innerHTML='<h2 id="recallBulkTitle">'+(done?'Take-back complete':started?'Agency take-back progress':'Review agency take-back')+'</h2>'+
  '<p>From <strong>'+esc(agency.name)+'</strong> to <strong>Owner / Master</strong></p>'+
  '<div class="agency-recall-availability"><strong>'+number(job.total)+' open leads in this preview</strong><span>Folder: '+esc(job.folder===null?'All folders':job.folder||'Untitled folder')+'</span><span>States: '+esc(job.states===null?'All states':job.states.map(s=>s||'State not set').join(', '))+'</span><span>'+number(job.assigned)+' assigned to agents / admins · '+number(job.total-job.assigned)+' in the agency pool</span></div>'+
  '<div class="agency-recall-table"><table><thead><tr><th>State</th><th>Open leads</th><th>Assigned</th></tr></thead><tbody>'+job.summary.map(s=>'<tr><td>'+esc(s.state||'State not set')+'</td><td>'+number(s.count)+'</td><td>'+number(s.assigned)+'</td></tr>').join('')+'</tbody></table></div>'+
  '<p class="agency-recall-note">Only the leads in this preview will be taken back. Notes, statuses and folder details stay with each lead. Closed deals and client records are preserved. Leads changed after this preview are left untouched and reported below.</p>'+
  '<div class="recall-bulk-progress"><progress id="recallBulkProgress" max="'+Number(job.total||1)+'" value="'+Number(job.processed||0)+'"></progress><strong id="recallBulkCounts">'+number(job.returned)+' returned · '+number(job.skipped)+' changed / skipped · '+number(job.total-job.processed)+' remaining</strong></div>'+
  '<p id="recallBulkMessage" role="status" class="muted small">'+(done?'All previewed leads have been checked.':started?'Resume this take-back, or stop and leave the remaining leads where they are.':'Review the count, then confirm. Nothing has been moved yet.')+'</p>'+
  '<div class="agency-recall-actions"><button type="button" id="recallBulkClose" class="btn secondary">'+(done?'Done':'Close')+'</button>'+(!done?'<button type="button" id="recallBulkStop" class="btn secondary">'+(started?'Stop take-back':'Change filters')+'</button><button type="button" id="recallBulkConfirm" class="btn primary">'+(started?'Resume take-back':'Take back '+number(job.total)+' leads')+'</button>':'')+'</div>';
  find('#recallBulkClose').onclick=async()=>{if(busy){close();return}root.remove();if(started||done){S.selected.clear();try{await reload(number(job.returned)+' leads taken back from '+agency.name+'.'+(job.skipped?' '+number(job.skipped)+' changed leads left untouched.':''))}catch(e){flash('Take-back saved. Reload to refresh the list.',true)}}};
  if(!done){
   find('#recallBulkStop').onclick=async()=>{
    if(busy)return;busy=true;controls();
    try{await api('/rest/v1/rpc/agency_recall_bulk_stop',{method:'POST',body:{p_source:agency.id,p_job:job.id}});if(!valid())return;root.remove();await openAgencyRecall(agency.id,agency)}catch(e){if(valid())find('#recallBulkMessage').textContent=e.message}finally{busy=false;if(valid())controls()}
   };
   find('#recallBulkConfirm').onclick=run;
  }
 }
 function controls(){
  if(!valid())return;
  root.setAttribute('aria-busy',String(busy));
  if(find('#recallBulkConfirm'))find('#recallBulkConfirm').disabled=busy;
  if(find('#recallBulkStop'))find('#recallBulkStop').disabled=busy;
  find('#recallBulkClose').textContent=busy?'Pause':complete()?'Done':'Close';
 }
 async function run(){
  if(busy||!valid()||complete())return;busy=true;pause=false;controls();
  try{
   while(valid()&&!pause&&!complete()){
    find('#recallBulkMessage').textContent='Returning leads… You can pause after the current group finishes.';
    const next=await api('/rest/v1/rpc/agency_recall_bulk_step',{method:'POST',body:{p_source:agency.id,p_job:job.id,p_offset:Number(job.processed)}});
    if(!valid())return;
    if(!next||next.id!==job.id||Number(next.processed)<=Number(job.processed))throw Error('Progress could not be confirmed. Close and reopen this agency to resume safely.');
    job=next;draw();controls();
   }
   if(valid()&&!complete())find('#recallBulkMessage').textContent='Paused. You can resume here or reopen Take back leads for this agency later.';
  }catch(e){if(valid())find('#recallBulkMessage').textContent=e.message+' Completed groups remain saved. Use Resume to retry safely.'}
  finally{busy=false;if(valid()){controls();if(find('#recallBulkConfirm'))find('#recallBulkConfirm').textContent='Resume take-back'}}
 }
 root.onclick=e=>{if(e.target===root&&!busy)close()};root.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();close()}};
 draw();find('#recallBulkClose').focus();
}
