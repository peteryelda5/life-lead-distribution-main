/* No credentials are sent to the worker. Only one bounded batch is in flight. */
let activeLeadImport=null;
function importProgressText(state){return state?.message||'Choose a CSV. Large files are read in small chunks; keep this tab open while uploading.';}
function paintImportProgress(){const s=activeLeadImport;if(!s)return;const p=q('#importProgress');if(p)p.textContent=importProgressText(s);const bar=q('#importBar');if(bar){bar.max=s.file.size;bar.value=s.bytes||0;}const pause=q('#pauseImport');if(pause)pause.disabled=!s.running;}
function pauseLeadImport(message='Paused. Select the same file, batch name, and source to resume.'){
 if(!activeLeadImport)return;activeLeadImport.worker?.terminate();activeLeadImport.running=false;activeLeadImport.message=message;paintImportProgress();const b=q('#uploadCsvBtn');if(b){b.disabled=false;b.textContent='Start / resume import';}
}
async function retryImportCall(path,opt){
 for(let attempt=0;;attempt++){try{return await api(path,opt);}catch(e){if(attempt>=4||([400,401,403,404,409,413,422].includes(e.status)&&e.code!=='40001'))throw e;
  if(activeLeadImport){activeLeadImport.message='Connection interrupted. Retrying the saved batch…';paintImportProgress();}
  await new Promise(resolve=>setTimeout(resolve,Math.min(16000,1000*2**attempt)));if(!activeLeadImport?.running)throw Error('Import paused.');
 }}
}
function openLargeCsvImport(){
 const div=S.profile?.is_super_admin?S.divisionFilter:S.profile?.division;
 if(!canAddLeads(div))return flash('Choose Vivid Life or Master to upload leads.',true);
 modal('<h2>Import CSV</h2><div class="notice">Import into <strong>'+esc(divisionLabel(div))+'</strong>. Every CSV column is preserved. Keep this tab open; if interrupted, select the same file to resume without repeating saved batches.</div><form id="csvForm" class="stack"><div class="field"><label>Lead type / batch name</label><input name="lead_type" required></div><div class="field"><label>Default source</label><input name="source" value="CSV import"></div><div class="field"><label>CSV file (UTF-8)</label><input name="file" type="file" accept=".csv,text/csv" required></div><progress id="importBar" style="width:100%" value="0" max="1"></progress><div id="importProgress" role="status" aria-live="polite" class="muted small"></div><div class="row"><button type="button" id="cancel" class="btn secondary">Close</button><button type="button" id="pauseImport" class="btn secondary" disabled>Pause</button><button id="uploadCsvBtn" class="btn primary right">Start / resume import</button></div></form>');
 q('#cancel').onclick=closeModal;q('#pauseImport').onclick=()=>pauseLeadImport();paintImportProgress();
 if(activeLeadImport?.running)q('#uploadCsvBtn').disabled=true;
 q('#csvForm').onsubmit=async e=>{
  e.preventDefault();if(activeLeadImport?.running)return;
  const f=new FormData(e.target),file=f.get('file'),leadType=String(f.get('lead_type')||'').trim(),source=String(f.get('source')||'').trim()||'CSV import';
  if(!(file instanceof File)||!file.size)return flash('Choose a non-empty CSV file.',true);
  if(!leadType)return flash('Enter a batch name.',true);
  if(!canAddLeads(div))return flash('Your division access changed. Reopen the importer.',true);
  const state={file,division:div,leadType,source,bytes:0,rows:0,running:true,message:'Checking the file for safe resume…',worker:new Worker('/csv-worker.js')};activeLeadImport=state;
  q('#uploadCsvBtn').disabled=true;paintImportProgress();
  let job,headers;
  const commit=async(rows,to,final=false)=>{
   const result=await retryImportCall('/rest/v1/rpc/commit_lead_import_batch',{method:'POST',body:{p_job:job.id,p_from:job.byte_offset,p_to:to,p_headers:headers||[],p_rows:rows,p_final:final}});
   Object.assign(job,result);state.bytes=job.byte_offset;state.rows=job.row_count;
   state.message=Number(job.row_count).toLocaleString()+' leads saved · '+(100*job.byte_offset/file.size).toFixed(1)+'% uploaded';paintImportProgress();
  };
  state.worker.onerror=()=>pauseLeadImport('The CSV worker stopped. Select the same file to resume.');
  state.worker.onmessage=async({data})=>{
   if(activeLeadImport!==state||!state.running)return;
   try{
    if(data.type==='hashing'){state.bytes=data.bytes;state.message='Checking file: '+(100*data.bytes/file.size).toFixed(1)+'%';paintImportProgress();return;}
    if(data.type==='fingerprint'){
     const params=new URLSearchParams({select:'*',owner_id:'eq.'+S.profile.id,division:'eq.'+div,fingerprint:'eq.'+data.hash,lead_type:'eq.'+leadType,default_source:'eq.'+source,limit:'1'});
     job=(await api('/rest/v1/lead_import_jobs?'+params))[0];
     if(!job){try{job=(await api('/rest/v1/lead_import_jobs',{method:'POST',headers:{Prefer:'return=representation'},body:{owner_id:S.profile.id,division:div,fingerprint:data.hash,filename:file.name,file_size:file.size,lead_type:leadType,default_source:source}}))[0];}catch(err){if(err.code!=='23505')throw err;job=(await api('/rest/v1/lead_import_jobs?'+params))[0];}}
     if(job.status==='completed'){pauseLeadImport('This exact file has already been imported into this division with this batch name and source.');return;}
     headers=job.headers;state.bytes=job.byte_offset;state.rows=job.row_count;
     state.message='Resuming from '+Number(job.row_count).toLocaleString()+' saved leads…';paintImportProgress();
     if(state.running)state.worker.postMessage({type:'ack',offset:job.byte_offset});return;
    }
    if(data.type==='batch'){
     let rawRows=data.rows;
     if(!headers){const first=rawRows[0];if(looksLikeHeader(first)){headers=rawRows.shift();}else headers=first.map((_,i)=>'Column '+(i+1));}
     let width=headers.length;for(const row of rawRows)width=Math.max(width,row.length);
     while(headers.length<width)headers.push('Unnamed Column '+(headers.length+1));
     const normalized=headers.map(normHeader);
     const get=(values,names)=>{for(const name of names){const i=normalized.indexOf(name);if(i>=0)return values[i]??'';}return '';};
     const rows=rawRows.map(values=>({first_name:get(values,['first_name','firstname','first','given_name'])||'',last_name:get(values,['last_name','lastname','last','surname','family_name'])||'',phone:get(values,['phone','phone_number','phonenumber','mobile','mobile_phone','cell','cell_phone','telephone'])||null,email:get(values,['email','email_address','emailaddress'])||null,state:get(values,['state','state_code','province'])||inferState(values)||null,source:get(values,['source','lead_source','leadsource'])||source,notes:get(values,['notes','note','comments','comment'])||null,csv_values:values}));
     await commit(rows,data.offset);
     if(state.running)state.worker.postMessage({type:'ack'});return;
    }
    if(data.type==='done'){
     if(!job.row_count)throw Error('No lead rows were found in the CSV.');
     await commit([],file.size,true);state.running=false;state.worker.terminate();state.message='Complete: '+Number(job.row_count).toLocaleString()+' leads saved.';paintImportProgress();
     S.poolPage=1;await loadCore();render();return;
    }
    if(data.type==='error')throw Error(data.message);
   }catch(error){pauseLeadImport('Import paused: '+error.message+' Saved batches are safe. Select the same file to resume.');}
  };
  state.worker.postMessage({type:'start',file});
 };
}
window.addEventListener('beforeunload',event=>{if(activeLeadImport?.running){event.preventDefault();event.returnValue='';}});
