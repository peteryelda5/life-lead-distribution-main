'use strict';
// Vercel bundles api/ and its lib/ dependencies separately. Only these browser
// assets belong in static output; never copy repository/configuration directories.
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),out=path.join(root,'public-site');
const extensions=new Set(['.html','.js','.css','.webmanifest','.mp4','.jpg','.jpeg','.png','.svg','.ico','.wav','.mp3','.pdf','.woff','.woff2']);
const textFiles=new Set(['life-insurance-101-transcript.txt','celebration-sound-credits.txt','robots.txt']);
function copy(from,to){const stat=fs.lstatSync(from);if(stat.isSymbolicLink())throw Error('Public assets must not be symlinks');if(stat.isDirectory()){fs.mkdirSync(to,{recursive:true});for(const name of fs.readdirSync(from)){if(name.startsWith('.'))continue;copy(path.join(from,name),path.join(to,name));}}else if(extensions.has(path.extname(from))||textFiles.has(path.basename(from))){fs.mkdirSync(path.dirname(to),{recursive:true});fs.copyFileSync(from,to);}}
fs.rmSync(out,{recursive:true,force:true});fs.mkdirSync(out);
for(const name of fs.readdirSync(root)){const file=path.join(root,name);if(name==='assets'||(fs.lstatSync(file).isFile()&&!name.startsWith('.')&&(extensions.has(path.extname(name))||textFiles.has(name))))copy(file,path.join(out,name));}
if(!fs.existsSync(path.join(out,'index.html')))throw Error('Missing public entry point');
console.log('Built browser-only static output in public-site; server source and migrations excluded.');
