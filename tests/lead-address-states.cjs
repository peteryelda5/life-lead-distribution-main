'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/../portal-app.js','utf8');
const nodes=new Map(),calls=[],messages=[];
class File {constructor(text){this.text=text;this.name='address-fixture.csv';this.size=text.length}}
const ctx=vm.createContext({File,FormData:class {constructor(form){this.form=form}get(k){return this.form[k]}},
 operatingDivision:()=> 'vivid_life',canAddLeads:()=>true,divisionLabel:()=> 'Vivid Life',esc:x=>String(x),modal(){},closeModal(){},S:{poolPage:3},
 q:s=>{if(!nodes.has(s))nodes.set(s,{});return nodes.get(s)},flash:(text,error)=>messages.push({text,error}),
 readLeadCsv:async file=>({text:file.text,removed:0}),api:async(path,options)=>calls.push({path,...JSON.parse(JSON.stringify(options))}),reload:async text=>messages.push({text})});
vm.runInContext(source.slice(source.indexOf('function parseCSV('),source.indexOf('function canAddLeads(')),ctx);
vm.runInContext(source.split('\n').find(line=>line.startsWith('function importCsvModal(')),ctx);
const infer=(headers,values)=>{ctx.headers=headers;ctx.values=values;return vm.runInContext('inferLeadState(headers,values)',ctx)};
const fixtures=[
 [['Address'],['123 Main St, Detroit, MI 48201'],'MI'],
 [['Full Address'],['123 Main St\nPortland, Oregon 97201-1234\nUnited States'],'OR'],
 [['Mailing Address'],['PO Box 123, Washington, DC 20001 USA'],'DC'],
 [['Street Address'],['123 Main St, Charlotte, North Carolina 28202'],'NC'],
 [['Address'],['123 Main St, Miami, FL'],'FL'],
 [['State','Address'],['TX','123 Main St, Detroit, MI 48201'],'TX'],
 [['State','State Code','Address'],['','CA','123 Main St, Detroit, MI 48201'],'CA'],
 [['State/City'],['TN, NASHVILLE'],'TN'],
 [['City State ZIP'],['Columbus OH 43215'],'OH'],
 [['First Name','Address'],['Georgia','123 Michigan Avenue'],''],
 [['First Name','Last Name','Notes'],['Georgia','Washington','Moved to MI 48201'],''],
 [['Address'],['123 Main St, Toronto, ON M5V 2T6'],''],
 [['Address','Mailing Address'],['123 Main St, Detroit, MI 48201','123 Main St, Austin, TX 78701'],''],
 [['Column 1','Column 2'],['Example','123 Main St, Detroit, MI 48201'],'MI'],
 [['Column 1','Column 2'],['Example','mi'],'MI'],
 [['Address'],['123 New York Avenue, Miami, FL 33101'],'FL'],
 [['State'],[' west virginia '],'WV'],
 [['Column 1'],['TN, NASHVILLE'],'TN'],
 [['Address'],['123 Washington'],''],
 [['Address'],['123 Main St, Washington'],''],
 [['Address'],['123 Main St, Detroit, Michigan'],'MI']
];
for(const [headers,values,expected]of fixtures)assert.equal(infer(headers,values),expected,JSON.stringify({headers,values}));
for(const code of 'AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC'.split(' '))assert.equal(infer(['Address'],['123 Main St, Example City, '+code+' 12345']),code);
(async()=>{
 vm.runInContext('importCsvModal()',ctx);
 const csv='First Name,Last Name,Address,State,Phone,Notes\nGeorgia,Example,"123 Michigan Ave, Detroit, MI 48201",,5550000001,Keep this note\nDemo,Example,"123 Main St, Austin, TX 78701",CA,5550000002,\nUnknown,Example,123 Michigan Avenue,,5550000003,\n';
 await nodes.get('#csvForm').onsubmit({preventDefault(){},target:{file:new File(csv),lead_type:'Address test',source:'Test import'}});
 assert.equal(calls.length,1);assert.equal(calls[0].path,'/rest/v1/leads');assert.equal(calls[0].method,'POST');
 assert.deepEqual(calls[0].body.map(x=>x.state),['MI','CA',null]);
 const first=calls[0].body[0];assert.equal(first.notes,'Keep this note');assert.equal(first.first_name,'Georgia');assert.equal(first.division,'vivid_life');
 assert.deepEqual(first.csv_headers,['First Name','Last Name','Address','State','Phone','Notes']);
 assert.deepEqual(first.csv_values,['Georgia','Example','123 Michigan Ave, Detroit, MI 48201','','5550000001','Keep this note']);
 assert.ok(messages.some(x=>x.text==='Imported 3 leads.'));assert.ok(!messages.some(x=>x.error));
 console.log('PASS: all 50 states + DC, address formats, explicit state priority, ambiguous/misleading text, and actual CSV upload payload with original cells preserved.');
})().catch(error=>{console.error(error);process.exitCode=1});
