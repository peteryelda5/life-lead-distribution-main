async function openLeadNameMatches(){
 const division=operatingDivision(), owner=S.profile.id, master=!!S.profile.is_super_admin;
 let scope=master?null:division, generation=0;
 modal('<h2>Find duplicates</h2><p class="muted">'+(master?'All folders across your agencies':'All lead folders in <strong>'+esc(divisionLabel(division))+'</strong>')+', including assigned and closed leads. A shared name alone does not identify the same person.</p>'+(master?'<label>Agency <select id="leadNameScope"><option value="">All agencies</option>'+adminDivisionList().map(id=>'<option value="'+esc(id)+'">'+esc(divisionLabel(id))+'</option>').join('')+'</select></label>':'')+'<div id="leadNameResults" aria-live="polite"></div><div class="row"><button class="btn secondary" id="leadNameClose">Close</button></div>');
 const box=q('#leadNameResults');
 q('#leadNameClose').onclick=closeModal;
 const current=()=>box.isConnected&&S.profile?.id===owner&&S.tab==='leads'&&division===operatingDivision();
 if(master)q('#leadNameScope').onchange=e=>{scope=e.target.value||null;load(0);};
 async function load(page){
  const request=++generation;
  box.textContent='Checking all folders…';
  try{
   const data=await api('/rest/v1/rpc/find_lead_name_duplicates',{method:'POST',body:{p_division:scope,p_page:page}});
   if(!current()||request!==generation)return;
   if(!data.total){box.textContent=scope?'No repeated full names found in this agency.':'No repeated full names found across your agencies.';return;}
   if(!data.groups.length&&page){return load(0);}
   const pages=Math.ceil(data.total/15);
   box.innerHTML='<p><strong>'+Number(data.total).toLocaleString()+' repeated names</strong> · Select a name to see its records.</p>'+data.groups.map(g=>'<details style="border-top:1px solid #dce6f1;padding:10px 0"><summary style="cursor:pointer"><strong>'+esc(g.name)+'</strong> · '+Number(g.count)+' records'+(g.records.some(r=>r.same_phone)?' · <b>Phone match</b>':'')+'</summary>'+g.records.map(r=>'<div style="padding:8px 12px;border-left:2px solid #c9dcf7;margin:8px 0"><strong>'+esc(r.agency)+' / '+esc(r.folder)+'</strong> · '+esc(r.status)+'<br>'+esc(r.phone||'No phone')+(r.same_phone?' · <b>Shared phone</b>':'')+'<br>'+esc(r.agent||'No assigned agent')+'</div>').join('')+'</details>').join('')+(pages>1?'<div class="row"><button id="leadNamePrev" class="btn secondary" '+(page===0?'disabled':'')+'>Previous</button><span>Page '+(page+1)+' of '+pages+'</span><button id="leadNameNext" class="btn secondary" '+(page+1>=pages?'disabled':'')+'>Next</button></div>':'');
   if(q('#leadNamePrev'))q('#leadNamePrev').onclick=()=>load(page-1);
   if(q('#leadNameNext'))q('#leadNameNext').onclick=()=>load(page+1);
  }catch(e){if(current()&&request===generation){box.textContent='Could not check for duplicates. ';const retry=document.createElement('button');retry.className='btn secondary';retry.textContent='Try again';retry.onclick=()=>load(page);box.append(retry);}}
 }
 await load(0);
}
