/* Vivid Life Portal: authenticated guide library and source-based case review. */
(function (root) {
 'use strict';
 const TOPICS = [
  [/diabet|a1c|insulin|blood sugar|hyperglyc/i,['diabetes','diabetic','insulin','A1C']],
  [/copd|emphysema|chronic bronchitis/i,['COPD','emphysema','bronchitis']],
  [/congestive|heart failure|\bchf\b|cardiomyopathy/i,['CHF','cardiomyopathy','heart failure']],
  [/cancer|tumou?r|malignan|chemotherapy|melanoma/i,['cancer','malignant','chemotherapy']],
  [/stroke|\btia\b|cerebrovascular/i,['stroke','TIA','cerebrovascular']],
  [/kidney|renal|dialysis|nephropathy/i,['kidney','renal','dialysis','nephropathy']],
  [/asthma/i,['asthma']], [/neuropathy/i,['neuropathy']], [/retinopathy/i,['retinopathy']],
  [/heart attack|myocardial|coronary|\bcad\b|stent|bypass/i,['coronary','myocardial','stent']],
  [/oxygen/i,['oxygen']], [/alzheimer|dementia/i,['Alzheimer','dementia']],
  [/depression|bipolar|mental|anxiety/i,['depression','bipolar','anxiety']],
  [/hiv|aids/i,['HIV','AIDS']], [/hepatitis|cirrhosis|liver/i,['hepatitis','cirrhosis','liver']],
  [/seizure|epilepsy/i,['seizure','epilepsy']], [/tobacco|smok|nicotine/i,['tobacco','nicotine']],
  [/obes|bmi|overweight/i,['obesity','BMI','build']], [/amputat/i,['amputation']]
 ];
 const STOP = new Set('a an the and or but with without for of to in on by is are was were i my we you client clients patient best better carrier carriers option options take through review where should could can would life insurance coverage policy final expense whole term universal indexed has have had years year old age diabetic details no yes not none please help client take state compare need suggest product products looking'.split(' '));
 function terms(question,medications='') {
  const text=String(question||'')+' '+String(medications||'');
  const hits=TOPICS.filter(([rx])=>rx.test(text));
  const words=(text.match(/[A-Za-z][A-Za-z-]{2,35}/g)||[]).map(s=>s.toLowerCase()).filter(s=>!STOP.has(s));
  return [...new Set([...hits.flatMap(t=>t[1]),...words])].slice(0,16);
 }
 function searchQuery(list){return list.map(t=>'"'+t.replace(/[^a-zA-Z0-9 -]/g,'')+'"').filter(t=>t!=='""').join(' OR ');}
 function number(value){return value===''||value==null?null:Number.isFinite(Number(value))?Number(value):null;}
 function missing(f,diabetes){
  const m=[];if(number(f.age)==null)m.push('Current age');if(!f.state)m.push('State');
  if(diabetes){if(!f.diabetesType||f.diabetesType==='unknown')m.push('Diabetes type');if(number(f.a1c)==null)m.push('Latest A1C and test date');if(number(f.diagnosisAge)==null)m.push('Age at diagnosis');if(!f.currentInsulin||f.currentInsulin==='unknown')m.push('Current insulin use');if(!f.insulin||f.insulin==='unknown')m.push('Insulin use in the past 12 months');if(!f.complications||f.complications==='unknown')m.push('Eye, kidney, nerve or amputation complications');if(!f.hospitalization||f.hospitalization==='unknown')m.push('Diabetes hospitalization in the past 24 months');if(!f.coronary||f.coronary==='unknown')m.push('Stroke or coronary disease history');}
  return m;
 }
 function ruleReview(g,f){
  const age=number(f.age),a1c=number(f.a1c),dx=number(f.diagnosisAge),r=g.rules?.type;
  const out={label:'Product-specific review',notes:[],pages:g.rules?.pages||[],caution:false};
  if(r==='corebridge-siwl-diabetes'){
   out.label='Review Level / Graded criteria';
   if(age!=null&&(age<50||age>80)){out.label='Outside stated issue ages';out.caution=true;out.notes.push('This SimpliNow Legacy guide lists issue ages 50–80.');}
   if(f.complications==='amputation'||f.hospitalization==='yes'||f.coronary==='yes'||a1c!=null&&a1c>=10){out.label='Decline criteria flagged';out.caution=true;out.notes.push('The diabetes chart lists decline for diabetes-related amputation, diabetes hospitalization in the last 24 months, stroke/coronary disease history, or A1C of 10+.');}
   else if(a1c!=null&&a1c<=8.6){out.notes.push('A1C 8.6 or less: the chart lists Level without insulin and Graded with insulin.');if(f.currentInsulin==='no')out.notes.push('The entered A1C and insulin answer align with the Level row only; other health and medication rules still apply.');}
   else if(a1c!=null&&a1c>=8.7&&a1c<=9.9)out.notes.push('A1C 8.7–9.9: the diabetes chart lists Graded.');
   else if(a1c!=null)out.notes.push('The entered A1C falls between printed thresholds. Confirm how the carrier treats it.');
   else out.notes.push('A1C 8.6 or less is Level without insulin / Graded with insulin; 8.7–9.9 is Graded; 10+ is Decline.');
   if(!f.currentInsulin||f.currentInsulin==='unknown')out.notes.push('Confirm current insulin use for the Level / Graded distinction. Past use alone does not resolve this row.');
   out.notes.push('Check all complications, health questions and combined medications. The guide includes separate polypharmacy decline examples.');
  } else if(r==='transamerica-fe-diabetes'){
   out.label='Review Premier / Select criteria';
   if(age!=null&&(age<18||age>85)){out.label='Outside stated adult issue ages';out.caution=true;out.notes.push('FE Express adult issue ages are 18–85; Graded is 18–80.');}
   out.notes.push('The single-condition chart lists Select for insulin treatment in the past 12 months, diagnosis before age 40, or diabetic eye/kidney/nerve complications.');
   out.notes.push('Premier requires diagnosis after age 40, no insulin, and no complications or comorbidities; build and overall case rules also apply.');
   if(f.state==='CA'){out.caution=true;out.notes.push('Premier is not available in California.');}
   if(dx===40)out.notes.push('Diagnosis at exactly age 40 is not resolved by the printed <40 / >40 rows. Confirm with the carrier.');
   out.notes.push('The single-condition chart is not an overall approval; review the comorbidity rules on page 9.');
  } else if(r==='foresters-planright-diabetes'){
   out.label='Review PlanRight condition / drug rows';
   out.notes.push('The drug matrix lists diabetes as Preferred for several diabetes medications. It lists diabetic nephropathy, neuropathy and retinopathy as Basic.');
   out.notes.push('Diabetes-related amputation is listed as No Coverage. Match the actual medication, indication and application answers.');
   if(f.complications==='amputation'){out.label='No Coverage criterion flagged';out.caution=true;}
  } else if(r==='ethos-field-diabetes'){
   if(f.coverage==='final-expense'){
    out.notes.push('Advantage Whole Life is simplified issue; this field guide points to separate TruStage underwriting and health-needs guides. A diabetes risk class is not established in this file.');
    out.notes.push('The Guaranteed Acceptance product lists ages 45–80, $2K–$25K, no health questions, and exclusions for WA / NY. Review its waiting-period benefits before considering it.');
    if(f.state==='WA'||f.state==='NY'){out.caution=true;out.notes.push('The listed Guaranteed Acceptance product is not available in the selected state.');}
    out.pages=[13,14,15];
   } else {out.notes.push('Ethos has distinct IUL and term products. Use the matching product section; a diabetes exclusion from one product must not be applied to another.');out.pages=[];}
  } else if(r==='instabrain-term-diabetes'){
   out.label='Review term exclusions';out.notes.push('Type I diabetes appears in the listed medical decline conditions. Prediabetes and gestational diabetes have separate criteria; they are not equivalent to Type II diabetes.');
   if(age!=null&&(age<18||age>60)){out.caution=true;out.notes.push('This term guide lists issue ages 18–60.');}
   if(f.diabetesType==='type1'){out.caution=true;out.label='Type I decline criterion flagged';}
  } else if(r==='instabrain-fe-diabetes'){
   out.label='Separate Final Expense from Guaranteed Issue';out.notes.push('The simplified-issue Final Expense application asks about diabetic complications, including amputation, coma and blindness. Read the complete questions and timeframes.');out.notes.push('Guaranteed Issue is a distinct product. Review its age limits, state availability and limited early death benefit before considering it.');
  } else if(r==='fg-brokerage-diabetes'){
   out.label='Review full underwriting requirements';out.notes.push('Insulin-treated diabetes can require an APS. Uncontrolled diabetes, significant complications or heart disease combined with diabetes are listed as issues that usually lead to a decline.');out.notes.push('The Preferred-class diabetes restriction does not mean every diabetic applicant is declined.');
  }
  return out;
 }
 function snippet(body,list){
  const lines=String(body||'').split(/\n/);const hit=lines.findIndex(l=>list.some(t=>l.toLowerCase().includes(t.toLowerCase())));
  const s=(hit<0?String(body||''):lines.slice(Math.max(0,hit-1),hit+3).join(' ')).replace(/\s+/g,' ').trim();
  return s.split(/\s+/).slice(0,12).join(' ')+(s.split(/\s+/).length>12?'…':'');
 }
 function caseFit(c,f,context){
  const type=c.guide.rules?.type,age=number(f.age),a1c=number(f.a1c),dx=number(f.diagnosisAge);
  const fit={strength:0,supported:false,excluded:false,reason:'This is a relevant guide section; the available evidence does not establish a best carrier for this case.'};
  if(f.currentInsulin==='yes'&&f.insulin==='no'){fit.reason='Current insulin use conflicts with the past-12-month answer. Confirm those details first.';return fit;}
  if(c.caution&&/Decline|No Coverage|Outside|Type I decline/.test(c.label)){fit.excluded=true;fit.reason='The entered case flags an exclusion or issue-age limit in this guide.';return fit;}
  if(context.complex||!context.diabetes||['gestational','prediabetes'].includes(f.diabetesType))return fit;
  const known=context.missing.length===0;
  if(type==='corebridge-siwl-diabetes'){
   if(age!=null&&(age<50||age>80)){fit.excluded=true;return fit;}
   if(f.complications==='amputation'||f.hospitalization==='yes'||f.coronary==='yes'||a1c!=null&&a1c>=10){fit.excluded=true;return fit;}
   if(a1c!=null&&a1c<=8.6&&f.currentInsulin==='no'&&f.complications==='none'){
    fit.strength=4;fit.supported=known;fit.reason='The entered A1C and no current insulin match the guide’s Level diabetes row. Review the complete health and medication history.';
   }else if(a1c!=null&&((a1c>=8.7&&a1c<=9.9)||(a1c<=8.6&&f.currentInsulin==='yes'))){fit.strength=2;fit.supported=known;fit.reason='These diabetes details match the guide’s Graded row. Review the benefit limitations and other supported options.';}
   else{fit.strength=1;fit.reason='This guide has explicit A1C and insulin criteria, but the entered details do not resolve the applicable row.';}
  }else if(type==='transamerica-fe-diabetes'){
   if(age!=null&&(age<18||age>85)){fit.excluded=true;return fit;}
   if(f.complications==='amputation'||f.complications==='other'||f.hospitalization==='yes'||f.coronary==='yes'){fit.strength=1;fit.reason='The full case needs the comorbidity chart; a single diabetes row cannot establish the strongest match.';return fit;}
   if(dx!=null&&dx>40&&f.insulin==='no'&&f.complications==='none'&&f.coronary==='no'&&f.state&&f.state!=='CA'){
    fit.strength=4;fit.supported=known;fit.reason='Diagnosis after age 40, no insulin, and no reported complications/comorbidities match the Premier diabetes row. Confirm build and full application criteria.';
   }else if(f.insulin==='yes'||dx!=null&&dx<40||f.complications==='eye-kidney-nerve'){
    fit.strength=3;fit.supported=known;fit.reason='The entered diabetes history matches a Select row in the guide. Confirm build, other conditions and state availability.';
   }else{fit.strength=1;fit.reason=f.state==='CA'?'Premier is unavailable in California; the current details do not establish another class.':'Confirm diagnosis age, insulin use and complications to resolve Premier versus Select.';}
  }else if(type==='foresters-planright-diabetes'){
   if(age!=null&&(age<50||age>85)||f.complications==='amputation'){fit.excluded=true;return fit;}
   if(f.hospitalization==='yes'||f.coronary==='yes'||f.complications==='other'){fit.reason='Additional medical history needs full case review; a drug row alone cannot determine the strongest carrier.';return fit;}
   if(f.complications==='eye-kidney-nerve'){fit.strength=1;fit.reason='The guide lists diabetic nephropathy, neuropathy and retinopathy as Basic; confirm the specific condition and benefit limits.';}
   else if(f.complications==='none'&&/\b(glipizide|glucophage|glyburide|janumet|januvia|jardiance|humalog|humulin)\b/i.test(f.medications||'')){
    fit.strength=4;fit.supported=known;fit.reason='The stated medication has a diabetes Preferred row in this guide. Verify the exact drug indication and all application answers.';
   }else{fit.strength=1;fit.reason='The drug/condition matrix is relevant, but the actual medication and indication need to be matched before selecting a class.';}
  }else if(type==='instabrain-term-diabetes'){
   if(f.diabetesType==='type1'||age!=null&&(age<18||age>60))fit.excluded=true;
  }
  if(fit.strength>0&&!known)fit.reason+=' Missing case details must be confirmed before treating this as the strongest match.';
  return fit;
 }
 function guideEdition(g){
  const value=String(g.version_label||'');const year=value.match(/20\d{2}/);if(!year)return 0;
  const months=['january','february','march','april','may','june','july','august','september','october','november','december'];const month=months.findIndex(m=>value.toLowerCase().includes(m));
  return Number(year[0])*12+Math.max(0,month);
 }
 function choosePrimary(candidates,f,context){
  for(const c of candidates)c.fit=caseFit(c,f,context);
  const ordered=candidates.filter(c=>!c.fit.excluded).sort((a,b)=>Number(b.fit.supported)-Number(a.fit.supported)||b.fit.strength-a.fit.strength||Number(b.guide.kind==='underwriting')-Number(a.guide.kind==='underwriting')||guideEdition(b.guide)-guideEdition(a.guide)||b.score-a.score||a.guide.carrier.localeCompare(b.guide.carrier));
  const primary=ordered[0]||null;
  const status=!primary?'no-supported-match':primary.fit.supported?'supported':context.missing.length?'needs-details':'guide-only';
  // One primary product per carrier; full source references remain available on demand.
  const seen=new Set(primary?[primary.guide.carrier]:[]),alternatives=[];
  for(const c of [...ordered.slice(1),...candidates.filter(c=>c.fit.excluded)]){if(!seen.has(c.guide.carrier)){seen.add(c.guide.carrier);alternatives.push(c);}}
  return {primary,alternatives,status,ranked:primary?[primary,...alternatives.filter(c=>!c.fit.excluded)]:[]};
 }

 function compare(guides,hits,f){
  const list=terms(f.question,f.medications);const diabetes=/diabet|a1c|insulin|blood sugar/i.test(f.question||'');
  // A negated condition or multiple conditions cannot safely drive a single-condition rule.
  const complex=/\b(no|not|without|non)\b[\s-]*(\w+\s+){0,2}(diabet|insulin)/i.test(f.question||'')||TOPICS.filter(([rx])=>rx.test(f.question||'')).length>1;
  const candidates=[];
  for(const g of guides){
   if(!g.active||g.kind==='rates'||!g.coverage_types?.includes(f.coverage))continue;
   const matches=hits.filter(h=>h.guide_id===g.id);const useRule=diabetes&&!complex&&!['gestational','prediabetes'].includes(f.diabetesType)&&g.rules?.type;
   if(!matches.length&&!useRule)continue;
   const review=useRule?ruleReview(g,f):{label:'Relevant guide sections',notes:['These sections mention the case terms. Check the original chart, product column, timeframes and full application before drawing a conclusion.'],pages:[],caution:false};
   const pages=[...new Set([...review.pages,...matches.map(h=>h.page_number)])].filter(p=>p>0&&p<=g.page_count);
   candidates.push({guide:g,...review,pages,matches:matches.slice(0,2).map(h=>({...h,excerpt:snippet(h.body,list)})),score:Math.max(0,...matches.map(h=>Number(h.score)||0))});
  }
  const context={missing:missing(f,diabetes),terms:list,complex,diabetes};
  const selected=choosePrimary(candidates,f,context);
  return {candidates,...context,...selected};
 }
 function pageRanges(value,max){
  if(!String(value||'').trim())return [{from:1,to:max}];
  return String(value).split(',').map(part=>{const m=part.trim().match(/^(\d+)(?:\s*-\s*(\d+))?$/);if(!m)throw Error('Use PDF page numbers such as 4-12, 25-29.');const from=Number(m[1]),to=Number(m[2]||m[1]);if(from<1||to<from||to>max)throw Error('The selected comparison pages are outside this PDF.');return {from,to};});
 }
 const engine={terms,searchQuery,missing,ruleReview,compare,snippet,pageRanges,caseFit,choosePrimary};
 root.PORTAL_UW_ENGINE=engine;
 if(typeof module!=='undefined'&&module.exports)module.exports=engine;
})(typeof window==='undefined'?globalThis:window);

if(typeof window!=='undefined'){
 const UW_CARRIERS=['Transamerica','Ethos','Corebridge Financial','Foresters Financial','Combined Insurance','SBLI','Aetna','Aflac','American Home Life','F&G','InstaBrain','Baltimore Life','Americo'];
 const UW_STATES='AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split(' ');
 const UW_BLANK={question:'',age:'',state:'',coverage:'final-expense',diabetesType:'unknown',insulin:'unknown',currentInsulin:'unknown',a1c:'',diagnosisAge:'',complications:'unknown',hospitalization:'unknown',coronary:'unknown',medications:''};
 const UW={tab:'library',guides:[],form:{...UW_BLANK},result:null,error:'',loading:false,userId:null,request:0};
 const UW_SELECT='id,slug,carrier,title,version_label,coverage_types,kind,notes,source_url,file_name,page_count,file_chunks,file_sha256,page_scopes,rules,active,updated_at';
 const uwLabel=c=>({'final-expense':'Final expense','term':'Term','iul':'IUL'}[c]||c);
 async function uwLoadGuides(){
  if(UW.userId!==S.profile?.id){UW.userId=S.profile?.id;UW.form={...UW_BLANK};UW.result=null;UW.loading=false;UW.error='';UW.tab='library';UW.request++;}
  const userId=S.profile?.id;try{const guides=await api('/rest/v1/underwriting_guides?select='+UW_SELECT+'&order=carrier.asc,title.asc&limit=500');if(userId!==S.profile?.id)return;UW.guides=guides;UW.error='';}catch(e){if(userId!==S.profile?.id)return;UW.guides=[];UW.error='The guide library could not load: '+e.message;}
 }
 function uwNav(){return '<div class="uw-tabs" role="tablist" aria-label="Carrier resources sections"><button class="'+(UW.tab==='library'?'active':'')+'" role="tab" aria-selected="'+(UW.tab==='library')+'" data-uw-tab="library">Carrier Library</button><button class="'+(UW.tab==='help'?'active':'')+'" role="tab" aria-selected="'+(UW.tab==='help')+'" data-uw-tab="help">Underwriting Help</button></div>';}
 function portalUnderwritingResourcesPage(){return uwNav()+(UW.tab==='help'?uwHelpPage():carrierLibraryPage());}
 function uwInput(label,name,type='text',extra=''){return '<label class="uw-field"><span>'+label+'</span><input name="'+name+'" type="'+type+'" value="'+esc(UW.form[name])+'" '+extra+'></label>';}
 function uwSelect(label,name,options){return '<label class="uw-field"><span>'+label+'</span><select name="'+name+'">'+options.map(([v,l])=>'<option value="'+v+'" '+(UW.form[name]===v?'selected':'')+'>'+l+'</option>').join('')+'</select></label>';}
 function uwHelpPage(){
  const yesno=[['unknown','Unknown'],['yes','Yes'],['no','No']];
  return '<section class="uw-page"><div class="head"><div><h1>Underwriting Help</h1><p>Compare cases using your carrier guides.</p></div>'+(S.profile?.is_super_admin?'<button class="btn secondary" id="uwManage">Manage guides</button>':'')+'</div>'+(UW.error?'<div class="notice" role="alert">'+esc(UW.error)+' <button class="btn secondary" id="uwRetry">Retry</button></div>':'')+'<div class="uw-grid"><div><form class="uw-panel" id="uwCaseForm"><h2>Describe the case</h2><label class="uw-field"><span>Your question</span><textarea name="question" rows="3" maxlength="1000" required placeholder="Where should I review a diabetic client for final expense?">'+esc(UW.form.question)+'</textarea></label><div class="uw-fields three">'+uwInput('Age','age','number','min="18" max="100" step="1" placeholder="e.g. 65"')+uwSelect('State','state',[['','Choose state'],...UW_STATES.map(s=>[s,s])])+uwSelect('Coverage type','coverage',[['final-expense','Final expense'],['term','Term'],['iul','IUL']])+'</div><h3>Additional details <span>(if known)</span></h3><div class="uw-fields two">'+uwSelect('Diabetes type','diabetesType',[['unknown','Unknown / not applicable'],['type1','Type I'],['type2','Type II'],['gestational','Gestational'],['prediabetes','Prediabetes']])+uwSelect('Currently using insulin','currentInsulin',yesno)+uwSelect('Insulin in past 12 months','insulin',yesno)+uwInput('Latest A1C','a1c','number','min="3" max="25" step="0.1" placeholder="Unknown"')+uwInput('Age at diagnosis','diagnosisAge','number','min="0" max="100" step="1" placeholder="Unknown"')+uwSelect('Diabetic complications','complications',[['unknown','Unknown'],['none','None confirmed'],['eye-kidney-nerve','Eye / kidney / nerve'],['amputation','Diabetes-related amputation'],['other','Other complication']])+uwSelect('Diabetes hospitalization, past 24 months','hospitalization',yesno)+uwSelect('Stroke / coronary disease history','coronary',yesno)+uwInput('Medications / indications','medications','text','maxlength="500" placeholder="e.g. metformin for diabetes"')+'</div><div id="uwCaseError" role="alert"></div><button class="btn primary uw-compare" '+(UW.loading?'disabled':'')+'>'+(UW.loading?'Comparing guides…':'Compare guides')+'</button><p class="uw-small">Use case details only. No client names needed. Cases stay in this browser session.</p></form><div class="uw-panel uw-confirm"><h2>Details to confirm</h2>'+((UW.result?.missing?.length?UW.result.missing:['Latest A1C, test date and age at diagnosis','Insulin use and recent hospitalizations','Eye, kidney, nerve or amputation complications','Complete medication list and other conditions']).map(t=>'<div class="uw-check"><span aria-hidden="true">□</span>'+esc(t)+'</div>').join(''))+'</div></div><div class="uw-results" aria-live="polite" aria-busy="'+UW.loading+'"><div class="uw-result-head"><h2>Carrier options to review</h2><span class="uw-status">'+(UW.loading?'Comparing…':!UW.result?'Awaiting case':UW.result.missing.length?'More details needed':UW.result.status==='supported'?'Strongest guide match':'Needs carrier review')+'</span></div>'+uwResultsHTML()+'<p class="uw-small uw-decision">Ranked using the available guides and your case details. Confirm product, state and full health history. Final decisions come from the carrier.</p></div></div>'+uwGuideLibrary()+'</section>';
 }
 function uwResultCard(c,index){
  const rank=Number.isInteger(index)?index+1:null;
  return '<article class="uw-panel uw-option uw-compact '+(rank===1?'uw-first':'')+'"><div class="uw-card-brand">'+carrierBrandLogo(c.guide.carrier)+'</div><div class="uw-card-body"><div class="uw-card-heading"><h3>'+esc(c.guide.carrier)+'</h3>'+(rank?'<span class="uw-rank">'+(rank===1?(c.fit.supported?'#1 · Best supported option':'#1 · Review first'):'#'+rank)+'</span>':'')+'</div><p class="uw-product">'+esc(c.guide.title)+'</p><div class="uw-option-label '+(c.caution?'uw-caution':'')+'">'+esc(c.label)+'</div><p class="uw-direct-answer">'+esc(c.fit.reason)+'</p><div class="uw-option-footer"><button class="btn secondary uw-open-guide" data-guide="'+c.guide.id+'" data-page="'+(c.pages[0]||1)+'">View guide'+(c.pages.length?' · p. '+c.pages.slice(0,4).join(', '):'')+'</button><span>'+esc(c.guide.version_label)+'</span></div><details class="uw-source-excerpts"><summary>Underwriting details &amp; sources</summary><ul>'+c.notes.map(n=>'<li>'+esc(n)+'</li>').join('')+'</ul>'+c.matches.map(m=>'<p><strong>PDF page '+m.page_number+'</strong><br>'+esc(m.excerpt)+'</p>').join('')+(c.guide.notes?'<p class="uw-guide-note">'+esc(c.guide.notes)+'</p>':'')+'</details></div></article>';
 }
 function uwResultsHTML(){
  if(!UW.result)return '<div class="uw-panel uw-empty"><div class="uw-search-mark" aria-hidden="true">⌕</div><h3>Find carrier options for your case</h3><p>Ask a question to see relevant carriers ranked with a short reason and their source guides.</p><button type="button" class="btn secondary" id="uwExample">Try a diabetes example</button></div>';
  const r=UW.result;
  if(!r.primary)return '<div class="uw-panel"><h3>No supported carrier match yet</h3><p>Confirm the health details or contact underwriting.</p></div>'+uwAlternativesHTML(r.alternatives);
  return (r.complex?'<div class="notice">These guide matches need a full review of the combined conditions.</div>':'')+(r.status!=='supported'?'<p class="uw-small uw-ranking-note">'+(r.status==='needs-details'?'Confirm the missing details below. This order is provisional.':'These are relevant guide references; the available evidence does not establish a best carrier.')+'</p>':'')+r.ranked.map((c,i)=>uwResultCard(c,i)).join('')+uwAlternativesHTML(r.alternatives.filter(c=>c.fit.excluded));
 }
 function uwAlternativesHTML(rows){return rows.length?'<details class="uw-alternatives"><summary>Options outside the documented criteria ('+rows.length+')</summary><div>'+rows.map(c=>uwResultCard(c)).join('')+'</div></details>':'';}
 function uwGuideLibrary(){return '<div class="uw-library-tools"><span class="uw-small">'+UW.guides.filter(g=>g.active).length+' source guides / references connected</span><button type="button" class="btn secondary" id="uwBrowseLibrary">Browse guide library</button></div>';}
 function uwSaveForm(form){UW.form={...UW_BLANK,...Object.fromEntries(new FormData(form))};}
 function uwBind(){
  qa('[data-uw-tab]').forEach(b=>b.onclick=()=>{const f=q('#uwCaseForm');if(f&&!UW.loading)uwSaveForm(f);UW.tab=b.dataset.uwTab;render();});
  if(q('#uwManage'))q('#uwManage').onclick=uwManageGuides;
  if(q('#uwBrowseLibrary'))q('#uwBrowseLibrary').onclick=uwBrowseLibrary;
  if(q('#uwRetry'))q('#uwRetry').onclick=async()=>{await uwLoadGuides();render();};
  if(q('#uwExample'))q('#uwExample').onclick=()=>{UW.form={...UW_BLANK,question:'Where should I review a diabetic client for final expense?'};UW.result=null;render();q('#uwCaseForm textarea')?.focus();};
  qa('[data-uw-carrier]').forEach(b=>b.onclick=()=>uwCarrierGuides(b.dataset.uwCarrier));
  uwBindOpenGuides();
  const f=q('#uwCaseForm');if(!f)return;
  f.querySelectorAll('input,textarea,select').forEach(el=>el.disabled=UW.loading);
  const changed=()=>{uwSaveForm(f);if(UW.result){UW.result=null;const results=q('.uw-results');if(results)results.innerHTML='<div class="uw-panel"><h2>Case details changed</h2><p>Click Compare guides to review the updated case.</p></div>';}};f.oninput=changed;f.onchange=changed;
  f.onsubmit=async e=>{
   e.preventDefault();if(UW.loading)return;uwSaveForm(f);const input={...UW.form};
   if(input.currentInsulin==='yes'&&input.insulin==='no'){q('#uwCaseError').textContent='Current insulin use means insulin was used within the past 12 months. Please correct those answers.';return;}
   if(input.diagnosisAge!==''&&input.age!==''&&Number(input.diagnosisAge)>Number(input.age)){q('#uwCaseError').textContent='Age at diagnosis cannot be greater than current age.';return;}
   const list=PORTAL_UW_ENGINE.terms(input.question,input.medications);if(!list.length){q('#uwCaseError').textContent='Enter a health condition or medication to search the guides.';return;}
   UW.loading=true;UW.error='';const request=++UW.request;render();
   try{const hits=await api('/rest/v1/rpc/search_underwriting_guides',{method:'POST',body:{query_text:PORTAL_UW_ENGINE.searchQuery(list),coverage_type:input.coverage}});if(request!==UW.request||UW.userId!==S.profile?.id)return;UW.result=PORTAL_UW_ENGINE.compare(UW.guides,hits||[],input);}catch(err){if(request===UW.request)UW.error='Comparison could not be completed: '+err.message;}finally{if(request===UW.request){UW.loading=false;if(S.tab==='carrier-resources')render();}}
  };
 }
 function uwBindOpenGuides(){qa('.uw-open-guide').forEach(b=>b.onclick=()=>uwOpenGuide(b.dataset.guide,Number(b.dataset.page)||1));}
 function uwBrowseLibrary(){
  closeModal();modal('<h2>Guide library</h2><div class="uw-guide-chips">'+UW_CARRIERS.map(c=>'<button type="button" class="uw-guide-chip" data-uw-carrier="'+esc(c)+'"><strong>'+esc(c)+'</strong><span>'+UW.guides.filter(g=>g.active&&g.carrier===c).length+' connected</span></button>').join('')+'</div><button class="btn secondary" id="uwClose">Close</button>');q('#uwClose').onclick=closeModal;qa('[data-uw-carrier]').forEach(b=>b.onclick=()=>uwCarrierGuides(b.dataset.uwCarrier));
 }
 function uwCarrierGuides(carrier){
  const guides=UW.guides.filter(g=>g.active&&g.carrier===carrier);
  modal('<h2>'+esc(carrier)+' guides</h2>'+(guides.length?guides.map(g=>'<div class="uw-guide-row"><div><strong>'+esc(g.title)+'</strong><p>'+esc(g.version_label)+' · '+g.coverage_types.map(uwLabel).join(', ')+' · '+esc(g.kind==='rates'?'Rate reference':g.kind==='product'?'Product reference':'Underwriting guide')+'</p><p class="uw-small">'+esc(g.notes)+'</p></div><button class="btn secondary uw-open-guide" data-guide="'+g.id+'" data-page="1">View guide</button></div>').join(''):'<p>No full underwriting guide is connected for this carrier yet. '+(carrier==='Combined Insurance'?'Combined remains pending.':'Add the carrier-issued guide when available.')+'</p>')+'<button class="btn secondary" id="uwClose">Close</button>');q('#uwClose').onclick=closeModal;uwBindOpenGuides();
 }
 async function uwOpenGuide(id,page=1){
  const g=UW.guides.find(x=>x.id===id);if(!g)return;
  closeModal();modal('<h2>'+esc(g.title)+'</h2><p>'+esc(g.version_label)+' · PDF page '+page+'</p><div id="uwPdfStatus" role="status">Opening protected guide…</div><div id="uwPdfView"></div><button class="btn secondary" id="uwClose">Close</button>');q('#uwClose').onclick=closeModal;
  const box=q('#modal .modalbox'),view=q('#uwPdfView'),status=q('#uwPdfStatus');box.classList.add('uw-pdf-modal');
  try{
   const chunks=await api('/rest/v1/underwriting_guide_file_chunks?select=chunk_number,data_base64&guide_id=eq.'+encodeURIComponent(id)+'&order=chunk_number.asc&limit=100');
   if(!view.isConnected||UW.userId!==S.profile?.id)return;
   if(chunks.length!==g.file_chunks||chunks.some((c,i)=>c.chunk_number!==i))throw Error('This source file is unavailable or incomplete. Refresh the guide library.');
   const bytes=uwDecode(chunks);const hash=await uwHash(bytes);if(hash!==g.file_sha256)throw Error('The source file could not be verified.');
   if(!view.isConnected)return;
   const url=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));
   view.innerHTML='<div class="row"><a class="btn primary" href="'+url+'#page='+page+'" target="_blank" rel="noopener noreferrer">Open PDF in new tab</a><a class="btn secondary" href="'+url+'" download="'+esc(g.file_name)+'">Download guide</a></div><iframe title="'+esc(g.title)+'" src="'+url+'#page='+page+'" class="uw-pdf-frame"></iframe>';status.textContent='Source PDF verified. Use the original product column and timeframes.';
   const cleanup=()=>URL.revokeObjectURL(url);q('#uwClose').onclick=()=>{cleanup();closeModal();};box.parentElement.onclick=e=>{if(e.target.id==='modal'){cleanup();closeModal();}};window.addEventListener('pagehide',cleanup,{once:true});setTimeout(cleanup,30*60*1000);
  }catch(e){if(status.isConnected)status.textContent=e.message;}
 }
 function uwDecode(chunks){const strings=chunks.map(c=>atob(c.data_base64));const out=new Uint8Array(strings.reduce((n,s)=>n+s.length,0));let pos=0;for(const s of strings){for(let i=0;i<s.length;i++)out[pos++]=s.charCodeAt(i);}return out;}
 async function uwHash(bytes){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');}
 function uwManageGuides(){
  if(!S.profile?.is_super_admin)return;
  closeModal();modal('<h2>Manage guides</h2><p>Add a carrier-issued PDF or replace an older edition. Only the Master can change this shared library.</p><button class="btn primary" id="uwAddGuide">Add guide</button><div class="uw-manage-list">'+UW.guides.map(g=>'<div class="uw-guide-row"><div><strong>'+esc(g.carrier)+' · '+esc(g.title)+'</strong><p>'+esc(g.version_label)+' · '+(g.active?'Live':'Archived / draft')+'</p></div><div class="row"><button class="btn secondary uw-open-guide" data-guide="'+g.id+'" data-page="1">View</button><button class="btn secondary" data-uw-replace="'+g.id+'">Replace</button><button class="btn secondary" data-uw-toggle="'+g.id+'">'+(g.active?'Archive':'Publish')+'</button></div></div>').join('')+'</div><div id="uwManageError" role="alert"></div><button class="btn secondary" id="uwClose">Close</button>');q('#modal .modalbox').classList.add('uw-manage-modal');q('#uwClose').onclick=closeModal;q('#uwAddGuide').onclick=()=>uwUploadGuide();uwBindOpenGuides();
  qa('[data-uw-replace]').forEach(b=>b.onclick=()=>uwUploadGuide(b.dataset.uwReplace));
  qa('[data-uw-toggle]').forEach(b=>b.onclick=async()=>{const g=UW.guides.find(x=>x.id===b.dataset.uwToggle);b.disabled=true;try{if(g.active)await api('/rest/v1/underwriting_guides?id=eq.'+g.id,{method:'PATCH',body:{active:false,updated_at:new Date().toISOString()}});else await api('/rest/v1/rpc/publish_underwriting_guide',{method:'POST',body:{new_guide_id:g.id,replace_guide_id:null}});UW.result=null;await uwLoadGuides();render();uwManageGuides();}catch(e){q('#uwManageError').textContent=e.message;b.disabled=false;}});
 }
 async function uwExtractPdf(bytes){
  const pdfjs=await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/5.4.149/pdf.min.mjs');pdfjs.GlobalWorkerOptions.workerSrc='https://cdnjs.cloudflare.com/ajax/libs/pdf.js/5.4.149/pdf.worker.min.mjs';
  const loading=pdfjs.getDocument({data:bytes.slice(),isEvalSupported:false});let pdf;
  try{pdf=await loading.promise;if(pdf.numPages>400)throw Error('Use a guide with 400 pages or fewer.');const pages=[];for(let n=1;n<=pdf.numPages;n++){const page=await pdf.getPage(n),content=await page.getTextContent();let lastY=null,text='';for(const item of content.items){if(!('str' in item))continue;const y=item.transform?.[5];if(lastY!==null&&Math.abs(y-lastY)>3)text+='\n';text+=item.str+(item.hasEOL?'\n':' ');lastY=y;}pages.push({page_number:n,body:text.slice(0,100000)});q('#uwUploadStatus').textContent='Reading PDF page '+n+' of '+pdf.numPages+'…';}if(pages.reduce((n,p)=>n+p.body.trim().length,0)<100)throw Error('This PDF has no usable searchable text. Upload a searchable carrier PDF.');return pages;}finally{await loading.destroy();}
 }
 function uwBase64(bytes){let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s);}
 function uwUploadGuide(replaceId){
  if(!S.profile?.is_super_admin)return;const old=UW.guides.find(g=>g.id===replaceId);
  closeModal();modal('<h2>'+(old?'Replace guide':'Add guide')+'</h2><form id="uwUploadForm" class="stack"><label class="uw-field"><span>Carrier</span><select name="carrier">'+UW_CARRIERS.map(c=>'<option '+(c===old?.carrier?'selected':'')+'>'+esc(c)+'</option>').join('')+'</select></label><label class="uw-field"><span>Guide title</span><input name="title" required maxlength="180" value="'+esc(old?.title||'')+'"></label><label class="uw-field"><span>Edition / revision</span><input name="version_label" required maxlength="100" placeholder="e.g. October 2026 · form number" value=""></label><fieldset><legend>Coverage types</legend>'+['final-expense','term','iul'].map(c=>'<label class="uw-coverage-check"><input name="coverage" type="checkbox" value="'+c+'" '+(old?.coverage_types.includes(c)?'checked':'')+'> '+uwLabel(c)+'</label>').join('')+'</fieldset><label class="uw-field"><span>Guide type</span><select name="kind">'+[['underwriting','Underwriting guide'],['product','Product reference'],['rates','Dated rate reference (excluded from comparisons)']].map(([v,l])=>'<option value="'+v+'" '+(old?.kind===v?'selected':'')+'>'+l+'</option>').join('')+'</select></label><label class="uw-field"><span>Scope / missing information</span><textarea name="notes" maxlength="2000" rows="2" placeholder="Product scope, state restrictions, or edition limitations">'+esc(old?.notes||'')+'</textarea></label><fieldset><legend>Pages to compare (optional)</legend><p class="uw-small">For mixed-product guides, enter the PDF pages for each selected coverage type. Leave blank to search all pages.</p><label class="uw-field"><span>Final expense PDF pages</span><input name="pages_fe" placeholder="e.g. 13-15, 25-29"></label><label class="uw-field"><span>Term PDF pages</span><input name="pages_term" placeholder="All pages"></label><label class="uw-field"><span>IUL PDF pages</span><input name="pages_iul" placeholder="All pages"></label></fieldset><label class="uw-field"><span>Carrier PDF (searchable, up to 20 MB)</span><input name="pdf" type="file" accept="application/pdf,.pdf" required></label>'+(old?'<p>This publishes a new edition and archives '+esc(old.version_label)+'. Existing reviewed rules are cleared; new material is searched directly until its product rules are reviewed.</p>':'')+'<label><input type="checkbox" name="authorized" required> This is carrier-issued material authorized for signed-in portal users.</label><div id="uwUploadStatus" role="status"></div><div id="uwUploadError" role="alert"></div><div class="row"><button class="btn primary">Publish guide</button><button type="button" class="btn secondary" id="uwUploadCancel">Cancel</button></div></form>');q('#modal .modalbox').classList.add('uw-manage-modal');q('#uwUploadCancel').onclick=uwManageGuides;
  q('#uwUploadForm').onsubmit=async e=>{
   e.preventDefault();const form=e.target,fd=new FormData(form),file=fd.get('pdf'),coverage=fd.getAll('coverage');const error=q('#uwUploadError'),status=q('#uwUploadStatus');error.textContent='';
   if(!coverage.length){error.textContent='Select at least one coverage type.';return;}if(old&&fd.get('carrier')!==old.carrier){error.textContent='A replacement must be for the same carrier.';return;}if(!file?.size||file.size>20*1024*1024){error.textContent='Choose a PDF up to 20 MB.';return;}
   const controls=[...form.elements];controls.forEach(el=>el.disabled=true);const overlay=q('#modal');overlay.onclick=()=>{};let id,published=false;
   try{
    status.textContent='Reading guide…';const bytes=new Uint8Array(await file.arrayBuffer());if(new TextDecoder().decode(bytes.slice(0,5))!=='%PDF-')throw Error('Choose a valid carrier PDF.');
    const pages=await uwExtractPdf(bytes),count=Math.ceil(bytes.length/294912),hash=await uwHash(bytes);
    const fields={'final-expense':'pages_fe',term:'pages_term',iul:'pages_iul'},hasScopes=coverage.some(c=>String(fd.get(fields[c])||'').trim());const scopes=hasScopes?coverage.flatMap(c=>PORTAL_UW_ENGINE.pageRanges(fd.get(fields[c]),pages.length).map(r=>({...r,coverage:[c]}))):[];
    const data={slug:'guide-'+crypto.randomUUID(),carrier:fd.get('carrier'),title:String(fd.get('title')).trim(),version_label:String(fd.get('version_label')).trim(),coverage_types:coverage,kind:fd.get('kind'),notes:String(fd.get('notes')).trim(),file_name:file.name.replace(/[^a-zA-Z0-9_.-]/g,'_'),page_count:pages.length,file_chunks:count,file_sha256:hash,active:false,rules:{},page_scopes:scopes};
    const added=await api('/rest/v1/underwriting_guides',{method:'POST',headers:{Prefer:'return=representation'},body:data});id=added?.[0]?.id;if(!id)throw Error('Guide record could not be created.');
    for(let i=0;i<count;i++){status.textContent='Saving protected PDF '+(i+1)+' of '+count+'…';await api('/rest/v1/underwriting_guide_file_chunks',{method:'POST',body:{guide_id:id,chunk_number:i,data_base64:uwBase64(bytes.subarray(i*294912,(i+1)*294912))}});}
    for(let i=0;i<pages.length;i+=20){status.textContent='Indexing source pages…';await api('/rest/v1/underwriting_guide_pages',{method:'POST',body:pages.slice(i,i+20).map(p=>({...p,guide_id:id}))});}
    status.textContent='Verifying and publishing…';await api('/rest/v1/rpc/publish_underwriting_guide',{method:'POST',body:{new_guide_id:id,replace_guide_id:old?.id||null}});published=true;UW.result=null;await uwLoadGuides();closeModal();render();flash('Guide published to the shared underwriting library.');
   }catch(err){if(id&&!published){try{await api('/rest/v1/underwriting_guides?id=eq.'+id,{method:'DELETE'});}catch{}}error.textContent=err.message;status.textContent=published?'The guide was published. Refresh the library.':'The previous live guide was kept.';controls.forEach(el=>el.disabled=false);overlay.onclick=e=>{if(e.target.id==='modal')closeModal();};}
  };
 }
 Object.assign(window,{uwLoadGuides,portalUnderwritingResourcesPage,uwBind,uwOpenGuide});
}

