'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),out=path.join(root,'public-site');
require('../scripts/build-public.cjs');
for(const name of ['lib','api','supabase','tests','scripts','node_modules','package.json','package-lock.json','vercel.json','AGENTS.md','SECURITY.md','.git','.env'])assert(!fs.existsSync(path.join(out,name)),name+' must not be served as static content');
for(const name of ['index.html','password-reset.html','portal-app.js','portal-push-sw.js','life-insurance-101.html','life-insurance-101.mp4','assets/login-mountains.mp4'])assert(fs.existsSync(path.join(out,name)),name+' must remain available');
const html=fs.readFileSync(path.join(out,'index.html'),'utf8');
for(const match of html.matchAll(/(?:src|href)="([^"#]+)"/g)){let src=match[1].split('?')[0];if(/^(https?:|data:)/.test(src))continue;assert(fs.existsSync(path.join(out,src)),src+' referenced by the portal is missing');}
const config=JSON.parse(fs.readFileSync(path.join(root,'vercel.json')));assert.equal(config.outputDirectory,'public-site');assert.equal(config.buildCommand,'node scripts/build-public.cjs');
console.log('PASS: browser assets and training video retained; server source, SQL, tests, configuration and credentials excluded from static output');
