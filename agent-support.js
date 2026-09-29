const SUPPORT={agentId:null,section:'open',type:'',page:1,count:0,rows:[],types:[]};
function resetAgentSupport(){Object.assign(SUPPORT,{agentId:null,section:'open',type:'',page:1,count:0,rows:[],types:[]})}
function supportAgent(){return S.profile?.role==='admin'&&S.profile.is_super_admin&&currentAal()==='aal2'?S.agents.find(a=>a.id===SUPPORT.agentId&&a.active&&!a.archived):null}
async function openAgentSupport(id){
 if(S.profile?.role!=='admin'||!S.profile.is_super_admin||currentAal()!=='aal2')throw new Error('Verified Master account required.');
 const a=S.agents.find(x=>x.id===id&&x.active&&!x.archived);if(!a)throw new Error('Active agent not found.');
 const ok=await api('/rest/v1/rpc/open_agent_support',{method:'POST',body:{p_agent:id}});
 if(ok!==true)throw new Error('Could not open this agent view.');
 SUPPORT.agentId=id;SUPPORT.section='open';SUPPORT.type='';SUPPORT.page=1;
 S.tab='support-agent';await loadAgentSupport();render();
}
async function loadAgentSupport(){
 const a=supportAgent();if(!a){resetAgentSupport();S.tab='agents';return}
 const p=new URLSearchParams();p.set('select',SUPPORT.section==='open'?'*':'*,leads(first_name,last_name,lead_type,csv_headers,csv_values)');
 if(SUPPORT.section==='open'){
  p.set('assigned_to','eq.'+a.id);p.set('status','eq.assigned');
  if(SUPPORT.type)p.set('lead_type',SUPPORT.type==='__unlabeled__'?'is.null':'eq.'+SUPPORT.type);
  p.set('order','is_dead_number.asc,assigned_at.desc,id.desc');
 }else{p.set('agent_id','eq.'+a.id);p.set('order','created_at.desc')}
 p.set('limit',String(S.pageSize));p.set('offset',String((SUPPORT.page-1)*S.pageSize));
 const result=await apiPage('/rest/v1/'+(SUPPORT.section==='open'?'leads':'closed_business')+'?'+p.toString());
 SUPPORT.rows=result.data||[];SUPPORT.count=Number(result.count||0);
 if(SUPPORT.section==='open'){
  SUPPORT.types=await api('/rest/v1/rpc/agent_reclaim_types',{method:'POST',body:{p_agent:a.id}})||[];
 }
 const pages=Math.max(1,Math.ceil(SUPPORT.count/S.pageSize));if(SUPPORT.page>pages){SUPPORT.page=pages;return loadAgentSupport()}
}
function agentSupportPage(){
 const a=supportAgent();if(!a)return '<div class="error">The selected agent is no longer available.</div>';
 const cols=SUPPORT.section==='open'?csvColumns(SUPPORT.rows):[];
 const menu='<div class="tools"><button class="btn secondary" id="supportBack">← Back to Agents</button><button class="btn '+(SUPPORT.section==='open'?'primary':'secondary')+' supportSection" data-section="open">Open leads</button><button class="btn '+(SUPPORT.section==='closed'?'primary':'secondary')+' supportSection" data-section="closed">Closed leads</button>'+(SUPPORT.section==='open'?'<select id="supportType" aria-label="Lead type"><option value="">All lead types</option>'+SUPPORT.types.map(x=>'<option value="'+esc(x.lead_type===null?'__unlabeled__':x.lead_type)+'" '+(SUPPORT.type===(x.lead_type===null?'__unlabeled__':x.lead_type)?'selected':'')+'>'+esc(x.lead_type||'Unlabeled')+' ('+Number(x.lead_count||0)+')</option>').join('')+'</select>':'')+'</div>';
 const pages=Math.max(1,Math.ceil(SUPPORT.count/S.pageSize));
 const nav='<div class="pager"><span class="muted small">Showing '+(SUPPORT.count?(SUPPORT.page-1)*S.pageSize+1:0)+'–'+Math.min(SUPPORT.page*S.pageSize,SUPPORT.count)+' of '+SUPPORT.count.toLocaleString()+'</span><div class="pages"><button class="btn secondary supportPage" data-page="'+(SUPPORT.page-1)+'" '+(SUPPORT.page<=1?'disabled':'')+'>Previous</button><span>Page '+SUPPORT.page+' of '+pages+'</span><button class="btn secondary supportPage" data-page="'+(SUPPORT.page+1)+'" '+(SUPPORT.page>=pages?'disabled':'')+'>Next</button></div></div>';
 let table;
 if(SUPPORT.section==='open')table='<div id="leadTopScroll" class="topscroll"><div id="leadTopScrollInner" class="topscroll-inner"></div></div><div id="leadTableScroll" class="table csvtable"><table><thead><tr><th>Lead type</th><th>Status</th>'+cols.map(c=>'<th>'+esc(c.label)+'</th>').join('')+'<th>Call notes</th></tr></thead><tbody>'+(SUPPORT.rows.length?SUPPORT.rows.map(l=>'<tr class="leadrow '+esc(l.agent_status||'none')+'"><td>'+esc(l.lead_type||'Unlabeled')+'</td><td>'+leadStatusBadge(l.agent_status)+'</td>'+cols.map(c=>'<td>'+esc(csvValue(l,c)||'—')+'</td>').join('')+'<td class="callnotes-view">'+esc(l.call_notes||'—')+'</td></tr>').join(''):'<tr><td colspan="'+(cols.length+3)+'" class="empty">No open leads in this folder.</td></tr>')+'</tbody></table></div>';
 else table='<div class="table"><table><thead><tr><th>Client</th><th>Lead type</th><th>Carrier</th><th>Policy type</th><th>Monthly</th><th>Annual</th><th>Date</th></tr></thead><tbody>'+(SUPPORT.rows.length?SUPPORT.rows.map(r=>'<tr><td>'+esc(closedClientName(r.leads))+'</td><td>'+esc(r.leads?.lead_type||'—')+'</td><td>'+esc(r.carrier||'—')+'</td><td>'+esc(r.policy_type||'—')+'</td><td>'+money(r.monthly_premium)+'</td><td>'+money(r.annual_premium)+'</td><td>'+esc(r.application_date||'—')+'</td></tr>').join(''):'<tr><td colspan="7" class="empty">No closed leads.</td></tr>')+'</tbody></table></div>';
 return '<div class="head"><div><h1>Agent view: '+esc(a.full_name)+'</h1><p>'+esc(divisionLabel(a.division))+' · Read-only support view. You remain signed in as '+esc(S.profile.full_name)+'.</p></div><div class="notice">This access is recorded under your Master account.</div></div>'+menu+'<p class="loadingline">Only '+S.pageSize+' records are loaded at a time.</p>'+nav+table+nav;
}
function bindAgentSupport(){if(S.tab!=='support-agent')return;
 const back=q('#supportBack');if(back)back.onclick=()=>{resetAgentSupport();S.tab='agents';render()};
 qa('.supportSection').forEach(b=>b.onclick=async()=>{SUPPORT.section=b.dataset.section;SUPPORT.page=1;SUPPORT.type='';try{await loadAgentSupport();render()}catch(e){flash(e.message,true)}});
 const type=q('#supportType');if(type)type.onchange=async()=>{SUPPORT.type=type.value;SUPPORT.page=1;try{await loadAgentSupport();render()}catch(e){flash(e.message,true)}};
 qa('.supportPage').forEach(b=>b.onclick=async()=>{SUPPORT.page=Number(b.dataset.page);try{await loadAgentSupport();render()}catch(e){flash(e.message,true)}});
 if(SUPPORT.section==='open')bindLeadTopScroll();
}
