const assert=require('node:assert/strict'),E=require('../underwriting.js');
const f={question:'diabetic final expense',coverage:'final-expense',age:'65',state:'MI',diabetesType:'type2',currentInsulin:'no',insulin:'no',a1c:'7.2',diagnosisAge:'50',complications:'none',hospitalization:'no',coronary:'no',medications:''};
const g=(id,carrier,type,version)=>({id,carrier,rules:{type,pages:[5]},active:true,coverage_types:['final-expense'],kind:'underwriting',page_count:30,version_label:version});
const ta=g('ta','Transamerica','transamerica-fe-diabetes','August 2026'),core=g('core','Corebridge Financial','corebridge-siwl-diabetes','April 2024'),ethos=g('ethos','Ethos','ethos-field-diabetes','September 2026');
let r=E.compare([core,ta,ethos],[],f);assert.equal(r.primary.guide.id,'ta');assert.equal(r.status,'supported');
r=E.compare([ta,core,ethos],[],{...f,state:'CA'});assert.equal(r.primary.guide.id,'core');assert.equal(r.status,'supported');
r=E.compare([ta,core,ethos],[],{...f,insulin:'yes',currentInsulin:'yes'});assert.equal(r.primary.guide.id,'ta');
r=E.compare([ta,core,ethos],[],{...f,a1c:'10'});assert.notEqual(r.primary.guide.id,'core');
r=E.compare([ta,core,ethos],[],{...f,age:'84'});assert.notEqual(r.primary.guide.id,'core');
r=E.compare([ta,core,ethos],[],{...f,diagnosisAge:'',a1c:'',insulin:'unknown'});assert.equal(r.status,'needs-details');assert.equal(r.primary.fit.supported,false);
// No fixed preference for Transamerica: case fit and source evidence decide.
const futureCore={...core,version_label:'September 2026'};r=E.compare([ta,futureCore],[],f);assert.equal(r.primary.guide.id,'core');
r=E.compare([core],[],{...f,a1c:'10'});assert.equal(r.primary,null);assert.equal(r.status,'no-supported-match');
r=E.compare([{...ta,id:'ta2'},ta,core],[],f);assert.equal(r.alternatives.filter(x=>x.guide.carrier==='Transamerica').length,0);
r=E.compare([ta,core],[],{...f,currentInsulin:'yes',insulin:'no'});assert.notEqual(r.status,'supported');
console.log('Case-based primary selection passed: CA, insulin, A1C, age, missing data, duplicate carriers and no fixed brand preference.');

r=E.compare([core,ta,ethos],[],f);assert.deepEqual(r.ranked.map(c=>c.guide.id),["ta","core","ethos"]);assert.equal(new Set(r.ranked.map(c=>c.guide.carrier)).size,r.ranked.length);
r=E.compare([ta,core,ethos],[],{...f,a1c:"10"});assert(!r.ranked.some(c=>c.guide.id==="core"));
console.log("Ranked options passed: best first, multiple relevant carriers, deduplication, and excluded criteria kept out of recommendations.");
