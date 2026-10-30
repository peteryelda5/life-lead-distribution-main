function agentOnboardingCard(preview=false){if(preview)return '';const ready=checklistOwner===S.profile.id,r=ready?checklistRecord:{},receipt=ready?checklistReceipt:null,a=ready?onboardSigning.agreement:null,resources=ready?onboardSigning.resources||{}:{},steps=ready?onboardingSteps():[false,false,false,false,false,false],count=steps.filter(Boolean).length,next=steps.indexOf(false);return '<section class="ad-card"><div class="ad-card-head"><h2>My onboarding</h2><span class="badge">'+(ready?count+' of 6 complete':'Review progress')+'</span></div>'+(ready?'<progress max="6" value="'+count+'" aria-label="Onboarding progress" style="width:100%;accent-color:#2563eb"></progress><p>'+(next<0?'Your onboarding checklist is complete.':'Next: <strong>'+esc(ONBOARD_STEPS[next][0])+'</strong>')+'</p>':'<p>Open onboarding to review your remaining steps.</p>')+(a?.waiting_on==='agency'?'<p class="ad-hint">Waiting on Peter Yelda’s signature</p>':'')+'<button class="btn primary" data-ad-go="onboarding">'+(ready&&count===6?'View onboarding':'Continue onboarding')+'</button></section>';}
function dashboardLeadName(r){if(!r)return 'Name not provided';const clean=v=>String(v??'').trim(),arr=v=>{if(Array.isArray(v))return v;try{return JSON.parse(v||'[]')}catch{return []}},hs=arr(r.csv_headers).map(h=>clean(h).toLowerCase().replace(/[^a-z0-9]/g,'')),vs=arr(r.csv_values),field=keys=>{for(const k of keys){const i=hs.indexOf(k);if(i>=0&&clean(vs[i]))return clean(vs[i]);}return '';};const first=clean(r.first_name)||field(['firstname','clientfirstname','insuredfirstname','fname','givenname']),last=clean(r.last_name)||field(['lastname','clientlastname','insuredlastname','lname','surname']);const name=[first,last].filter(Boolean).join(' ')||field(['fullname','clientname','name','insuredname','contactname','applicantname']);return name||clean(r.phone)||field(['phone','phonenumber','mobile','cellphone','telephone'])||'Name not provided';}
/* Personal dashboard shared by agent login and Master read-only preview. */
// Original portal encouragement; one shared quote per Eastern calendar day.
const AGENT_DAILY_QUOTES=[
 'Small, consistent steps create lasting progress.',
 'Listen closely. The next conversation deserves your full attention.',
 'Preparation turns a good intention into a better conversation.',
 'Focus on the person, and let the conversation follow.',
 'Progress begins with the next thoughtful action.',
 'Build trust one clear answer at a time.',
 'A strong day starts with a simple plan.',
 'Be patient with the process and deliberate with your effort.',
 'Every conversation is a chance to understand someone better.',
 'Your best work starts with showing up prepared.',
 'Consistency matters most on the days it feels hardest.',
 'Make today’s follow-through tomorrow’s foundation.',
 'Ask better questions. Give people room to answer.',
 'Confidence grows when preparation meets practice.',
 'Let each conversation teach you something useful.',
 'Take pride in the effort you can control.',
 'Clear explanations build stronger relationships.',
 'The next small improvement is worth making.',
 'Bring a fresh perspective to today’s opportunities.',
 'Good service begins with genuine curiosity.',
 'Follow up with purpose and respect people’s time.',
 'Your habits shape your momentum.',
 'A thoughtful pause can improve the whole conversation.',
 'Celebrate progress, then build on it.',
 'Keep your promises, especially the small ones.',
 'A difficult day can still be a day of growth.',
 'Be clear about the next step and thoughtful about the timing.',
 'The strongest relationships are built through steady care.',
 'Start with one priority and give it your full focus.',
 'Learn from yesterday without letting it limit today.',
 'Good questions open the door to useful answers.',
 'Aim to leave each person better informed.',
 'Make room for learning in every working day.',
 'Your next conversation is a new beginning.',
 'Reliable follow-through makes your work stand out.',
 'Stay curious, stay prepared, and keep improving.',
 'Small wins deserve recognition too.',
 'Do the important things with care, not just speed.',
 'Take the time to understand before offering a solution.',
 'A clear plan makes the next step easier.',
 'Practice today what you want to do well tomorrow.',
 'Steady effort can turn uncertainty into confidence.',
 'Make your notes as helpful as your conversation.',
 'Bring patience to the process and energy to your work.',
 'A goal gives direction. Daily habits create progress.',
 'Choose one skill to strengthen today.',
 'Respectful conversations create room for trust.',
 'What you learn today can improve tomorrow’s approach.',
 'You do not need a perfect day to make meaningful progress.',
 'Keep your focus on helping people make informed choices.',
 'Start fresh, stay organized, and follow through.',
 'The quality of your attention matters.',
 'A useful conversation begins with an open mind.',
 'Let preparation do some of the heavy lifting.',
 'Your progress is built one working day at a time.',
 'Take the next step with purpose.',
 'Be someone people can rely on for a clear answer.',
 'Good teamwork begins with sharing what you learn.',
 'Finish today with tomorrow’s first step in mind.',
 'Bring your best effort to the opportunity in front of you.'
];
function agentDailyQuote(now=new Date()){
 const parts=new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now),part=type=>Number(parts.find(p=>p.type===type).value);
 const day=Math.floor(Date.UTC(part('year'),part('month')-1,part('day'))/86400000);
 return AGENT_DAILY_QUOTES[((day%AGENT_DAILY_QUOTES.length)+AGENT_DAILY_QUOTES.length)%AGENT_DAILY_QUOTES.length];
}
function refreshAgentDailyQuote(){const node=document.querySelector('[data-ad-daily-quote]');if(node&&!document.hidden)node.textContent=agentDailyQuote();}
let agentQuoteTimer=null;
if(typeof document!=='undefined')document.addEventListener('visibilitychange',refreshAgentDailyQuote);
let AD={data:null,error:'',owner:null,period:'month',request:0,boards:{},boardErrors:{},boardRequest:0};
function resetAgentDashboard(){clearInterval(agentQuoteTimer);agentQuoteTimer=null;AD={data:null,error:'',owner:null,period:'month',request:AD.request+1,boards:{},boardErrors:{},boardRequest:AD.boardRequest+1};}
async function loadAgentDashboardBoard(agent,period=AD.period){
 const request=++AD.boardRequest,owner=AD.owner;
 try{const board=await api('/rest/v1/rpc/leaderboard_period',{method:'POST',body:{p_division:leaderboardDefaultScope(agent),p_period:period,p_month:null}});if(owner===AD.owner&&request===AD.boardRequest){AD.boards[period]=board;delete AD.boardErrors[period];}}
 catch(e){if(owner===AD.owner&&request===AD.boardRequest)AD.boardErrors[period]=e.message||'Production unavailable';}
}
async function loadAgentDashboard(id=S.profile?.id){
 const n=++AD.request;AD.data=null;AD.error='';AD.owner=id;AD.boards={};AD.boardErrors={};
 const agent=id===S.profile?.id?S.profile:supportAgent();
 try{const [d,recent]=await Promise.all([api('/rest/v1/rpc/agent_dashboard',{method:'POST',body:{p_agent:id}}),api('/rest/v1/closed_business?select=id,carrier,policy_type,annual_premium,monthly_premium,application_date,created_at,leads(first_name,last_name,csv_headers,csv_values)&agent_id=eq.'+encodeURIComponent(id)+'&order=created_at.desc,id.desc&limit=6').catch(()=>null),id===S.profile?.id&&S.profile.role==='agent'?loadOnboardingChecklist().catch(()=>{}):Promise.resolve(),agent?loadAgentDashboardBoard(agent):Promise.resolve(),typeof loadCarrierLogos==='function'?loadCarrierLogos():Promise.resolve()]);if(n===AD.request&&AD.owner===id)AD.data=Array.isArray(recent)?{...d,recent}:d;}catch(e){if(n===AD.request)AD.error=e.message;}
}
function agentDashboardGoal(id,preview=false){
 const g=PC.goalAgent===id?PC.goal:null,target=Number(g?.target||0),production=Number(g?.production||0),percent=target?Math.max(0,Math.round(production/target*100)):0;
 return '<section class="ad-card ad-goal pc-goal"><div class="ad-card-head"><div><h2>Production goal</h2><p class="ad-hint">Monthly AP · '+esc(new Date(PC.goalMonth+'T12:00:00').toLocaleDateString('en-US',{month:'long'}))+'</p></div>'+(S.profile.role==='admin'&&!preview?'<button class="ad-link" id="pcSetGoal">Edit goal</button>':'')+'</div>'+(g?'<div class="ad-goal-body"><div class="ad-ring" style="--progress:'+Math.min(100,percent)+'" role="progressbar" aria-label="Monthly production goal" aria-valuemin="0" aria-valuemax="100" aria-valuenow="'+Math.min(100,percent)+'"><strong>'+percent+'%</strong></div><div class="ad-goal-numbers"><strong>'+money(production)+'</strong><span>/ '+(target?money(target)+' goal':'No goal set')+'</span><p><i class="ad-dot"></i>'+money(production)+' submitted AP</p><p><i class="ad-dot muted"></i>'+(target?money(Math.max(0,target-production))+' to go':'Ask your admin to set a goal')+'</p></div></div>':'<p role="status">Goal unavailable. Refresh to retry.</p>')+'</section>';
}
function agentDashboardPage(agent=S.profile,preview=false){
 const d=AD.owner===agent?.id?AD.data:null,num=v=>v==null?'—':Number(v).toLocaleString(),name=(agent?.full_name||'Agent').split(' ')[0],hour=Number(new Intl.DateTimeFormat('en-US',{timeZone:'America/Detroit',hour:'numeric',hourCycle:'h23'}).format(new Date())),greeting=hour<12?'Good morning':hour<18?'Good afternoon':'Good evening';
 const periodName={today:'Today',week:'This week',month:'This month'}[AD.period],apLabel={today:'Today’s AP',week:'Weekly AP',month:'Monthly AP'}[AD.period];
 const head='<header class="ad-head"><div><h1>'+greeting+', '+esc(name)+'</h1><p class="ad-daily-quote"><span class="ad-quote-label">TODAY’S INSPIRATION</span><span data-ad-daily-quote>'+esc(agentDailyQuote())+'</span></p></div><div class="ad-header-tools"><div class="ad-periods" aria-label="Production reporting period">'+['today','week','month'].map(v=>'<button data-ad-period="'+v+'" aria-pressed="'+(v===AD.period)+'">'+v[0].toUpperCase()+v.slice(1)+'</button>').join('')+'</div><span class="ad-date">'+esc(new Date().toLocaleDateString('en-US',{timeZone:'America/Detroit',month:'long',year:'numeric'}))+'</span></div></header>';
 if(!d)return '<section class="agent-dashboard">'+head+'<div class="ad-card" role="status">'+esc(AD.error||'Loading your dashboard…')+' <button class="btn secondary" id="adRetry">Retry</button></div></section>';
 const board=AD.boards[AD.period],ranks=board?.rankings||[],personal=ranks.find(r=>r.agent_id===agent.id),ap=board?Number(personal?.ap||0):null,deals=board?(personal?personal.deals:0):null,rank=personal?ranks.findIndex(r=>r.agent_id===agent.id)+1:null;
 const metric=(label,value,icon,hint,tab,link)=>'<article class="ad-metric"><span class="ad-icon">'+sidebarIcon(icon)+'</span><div><h2>'+label+'</h2><strong>'+value+'</strong><small>'+hint+'</small></div><button class="ad-link" data-ad-go="'+tab+'">'+link+' <span aria-hidden="true">→</span></button></article>';
 const action=(title,hint,tab,link,icon)=>'<div class="ad-next-row"><span class="ad-icon">'+sidebarIcon(icon)+'</span><div><strong>'+title+'</strong><small>'+hint+'</small></div><button class="ad-action" data-ad-go="'+tab+'">'+link+'</button></div>';
 const monthly=PC.goalAgent===agent.id&&PC.goal?Number(PC.goal.production||0):AD.boards.month?Number(AD.boards.month.rankings.find(r=>r.agent_id===agent.id)?.ap||0):null;
 const recent=(d.recent||[]).map(r=>{const client=dashboardLeadName(r.leads),initials=client.split(/\s+/).slice(0,2).map(n=>n[0]).join('');return '<tr><td><div class="ad-client"><span class="ad-initials">'+esc(initials)+'</span><strong>'+esc(client)+'</strong></div></td><td><div class="ad-carrier">'+(typeof carrierBrandLogo==='function'?(carrierBrandLogo(r.carrier)||esc(r.carrier||'—')):esc(r.carrier||'—'))+(r.policy_type?'<small>'+esc(r.policy_type)+'</small>':'')+'</div></td><td>'+esc(r.created_at?new Date(r.created_at).toLocaleDateString('en-US',{timeZone:'America/Detroit',month:'short',day:'numeric',year:'numeric'}):'—')+'</td><td class="ad-ap">'+money(r.annual_premium)+' <small>AP</small></td><td><button class="ad-link" data-ad-deal="'+esc(r.id)+'" aria-label="Open deal for '+esc(client)+'">→</button></td></tr>';}).join('');
 return '<section class="agent-dashboard">'+head+'<div class="ad-metrics">'+metric('My assigned leads',num(d.assigned),'my-leads','Available in your folders','my-leads','View leads')+metric('Deals submitted',num(deals),'my-closed',periodName,'my-closed','View deals')+metric(apLabel,ap===null?'—':money(ap),'dashboard','Annualized premium submitted','leaderboard','View production')+metric('Callbacks / follow-ups',num(d.followups),'lead-requests','Open follow-ups','followups','View follow-ups')+'</div>'+(AD.boardErrors[AD.period]?'<p class="ad-error" role="status">Production and rank unavailable. <button class="ad-link" id="adBoardRetry">Retry</button></p>':!board?'<p class="ad-hint" role="status">Loading '+periodName.toLowerCase()+' production…</p>':'')+'<div class="ad-momentum">'+agentDashboardGoal(agent.id,preview)+'<section class="ad-card ad-rank"><div class="ad-rank-heading"><span aria-hidden="true">🏆</span><div><h2>Your rank</h2><p class="ad-hint">Leaderboard standing · '+apLabel+'</p></div></div><strong class="ad-rank-number">'+(rank?'#'+rank:'—')+'</strong><p class="ad-rank-total">'+(board?'out of '+ranks.length+' producers':'Loading agency ranking…')+'</p>'+(rank&&ap>0&&rank<=5?'<span class="ad-rank-badge">🏆 Top 5 · '+periodName.toLowerCase()+'</span>':'<p class="ad-hint">'+(ap===0?'Your next submission starts your climb.':'Keep building your momentum.')+'</p>')+'<button class="ad-link" data-ad-go="leaderboard">View leaderboard →</button></section><section class="ad-card ad-milestones"><h2>Milestones</h2><p class="ad-hint">Monthly submitted AP</p><ol>'+[10000,15000,25000,50000].map(v=>'<li class="'+(monthly!==null&&monthly>=v?'achieved':'')+'"><span aria-label="'+(monthly===null?'Unavailable':monthly>=v?'Achieved':'Not yet achieved')+'">'+(monthly!==null&&monthly>=v?'✓':'')+'</span>'+money(v).replace('.00','')+' AP</li>').join('')+'</ol></section></div><section class="ad-card ad-next"><h2>Next actions</h2><div>'+action('Follow up with your leads',num(d.followups)+' callbacks / follow-ups','followups','View leads','lead-requests')+action('Review your client tasks','Open your CRM follow-ups and reminders','crm-tasks','View tasks','book-business')+action('Record your next deal','Keep your production up to date','log-deal','Log a deal','my-closed')+'</div></section><section class="ad-card ad-recent"><div class="ad-card-head"><div><h2>Recent closings</h2><p class="ad-hint">Your latest submitted deals</p></div><button class="ad-link" data-ad-go="my-closed">View all deals →</button></div><div class="ad-table"><table><thead><tr><th>Client</th><th>Carrier / product</th><th>Submitted</th><th>Annualized premium</th><th><span class="sr-only">Open deal</span></th></tr></thead><tbody>'+ (recent||'<tr><td colspan="5" class="ad-empty">Your submitted deals will appear here.</td></tr>')+'</tbody></table></div><div class="ad-recent-footer"><p class="ad-hint">Showing '+(d.recent||[]).length+' recent submissions</p><button class="ad-link" data-ad-go="my-closed">View more closings</button></div></section><details class="ad-more"><summary>My follow-ups & onboarding</summary><div class="ad-columns"><section class="ad-card"><h2>My follow-ups</h2>'+((d.priorities||[]).map(r=>'<div class="ad-priority"><div><strong>'+esc(dashboardLeadName(r))+'</strong><small>'+esc(r.lead_type||'Lead')+'</small></div><button class="ad-action" data-ad-lead="'+esc(r.id)+'">Open lead</button></div>').join('')||'<p class="ad-empty">No follow-ups yet.</p>')+'</section>'+agentOnboardingCard(preview)+'</div></details></section>';
}
function bindAgentDashboard(preview=false){refreshAgentDailyQuote();if(!agentQuoteTimer)agentQuoteTimer=setInterval(refreshAgentDailyQuote,30000);const agent=preview?supportAgent():S.profile;if(!agent)return;
 if(q('#adRetry'))q('#adRetry').onclick=async()=>{await loadAgentDashboard(agent.id);render();};
 const refreshBoard=async()=>{const period=AD.period;await loadAgentDashboardBoard(agent,period);if(AD.owner===agent.id&&AD.period===period&&(S.tab==='dashboard'||preview))render();};
 if(q('#adBoardRetry'))q('#adBoardRetry').onclick=refreshBoard;
 qa('[data-ad-period]').forEach(b=>b.onclick=async()=>{AD.period=b.dataset.adPeriod;render();await refreshBoard();});
 qa('[data-ad-deal]').forEach(b=>b.onclick=()=>preview?go('my-closed'):openClosedDeal(b.dataset.adDeal));
 const go=async(tab,id)=>{try{if(tab==='leaderboard'){if(LB.owner!==S.profile.id){resetLeaderboard();LB.owner=S.profile.id;}LB.period=AD.period;LB.division=leaderboardDefaultScope(agent);await navigatePortalTab('leaderboard');return;}if(tab==='followups'){const details=q('.ad-more');if(details){details.open=true;details.scrollIntoView({behavior:'smooth',block:'start'});}return;}if(preview){SUPPORT.section=tab==='my-closed'?'closed':'open';SUPPORT.page=1;SUPPORT.type='';await loadAgentSupport();render();return;}
 S.tab=['add-client','crm-tasks'].includes(tab)?'book-business':['log-deal','followups'].includes(tab)?'my-leads':tab;S.myPage=1;S.myClosedPage=1;if(S.tab==='my-leads'){S.myFolder=null;S.mySearch='';S.myStates=[];S.filter='';}await loadTabData();render();if(tab==='add-client')q('#bobAddClient')?.click();if(tab==='crm-tasks')q('[data-bob-tab=tasks]')?.click();if(tab==='log-deal')flash('Choose the client’s Close button in My Leads to record the deal.');if(id){const button=qa('.closeLead').find(b=>b.dataset.id===id);button?.closest('tr')?.scrollIntoView({behavior:'smooth',block:'center'});}
 }catch(e){flash(e.message,true);}};
 qa('[data-ad-go]').forEach(b=>b.onclick=()=>go(b.dataset.adGo));qa('[data-ad-lead]').forEach(b=>b.onclick=()=>go('my-leads',b.dataset.adLead));
}
