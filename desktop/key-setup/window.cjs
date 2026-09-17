'use strict';
const {app,BrowserWindow,session,ipcMain,dialog,safeStorage,powerMonitor}=require('electron');
const fs=require('node:fs/promises'),path=require('node:path');
const {Vault}=require('./vault.cjs');
function register(){
 const vault=new Vault(path.join(app.getPath('userData'),'master-key-preparation.bin'),{
  isAsyncEncryptionAvailable:()=>process.platform==='win32'?safeStorage.isAsyncEncryptionAvailable():Promise.resolve(false),
  encryptStringAsync:value=>safeStorage.encryptStringAsync(value),decryptStringAsync:value=>safeStorage.decryptStringAsync(value)
 });
 const ses=session.fromPartition('lld-key-setup');let win=null,busy=false;
 const routes={'/setup.html':['setup.html','text/html'],'/setup.js':['setup.js','text/javascript'],'/setup.css':['setup.css','text/css']};
 const allowed=raw=>{try{const u=new URL(raw);return u.protocol==='lld-keys:'&&u.host==='setup'&&!u.username&&!u.password&&!u.search&&Object.hasOwn(routes,u.pathname);}catch{return false;}};
 ses.setPermissionRequestHandler((_w,_p,cb)=>cb(false));ses.setPermissionCheckHandler(()=>false);
 ses.webRequest.onBeforeRequest((details,cb)=>cb({cancel:!allowed(details.url)}));
 ses.on('will-download',event=>event.preventDefault());
 ses.protocol.handle('lld-keys',async request=>{if(request.method!=='GET'||!allowed(request.url))return new Response('Not found',{status:404});const [file,type]=routes[new URL(request.url).pathname];return new Response(await fs.readFile(path.join(__dirname,file)),{headers:{'Content-Type':type+'; charset=utf-8','Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",'X-Content-Type-Options':'nosniff'}});});
 async function chooseFile(){const result=await dialog.showOpenDialog(win,{title:'Select your encrypted recovery file',properties:['openFile'],filters:[{name:'LLD recovery',extensions:['lldkey']}]});if(result.canceled)return null;const file=result.filePaths[0];if((await fs.stat(file)).size>32768)throw Error('Recovery file is too large');return fs.readFile(file,'utf8');}
 const actions={status:()=>vault.status(),create:p=>vault.create(p),unlock:p=>vault.unlock(p),lock:()=>{vault.lock();return {message:'Local preparation key locked.'};},backup:async()=>{const text=await vault.backup();const result=await dialog.showSaveDialog(win,{title:'Save encrypted Master recovery file',defaultPath:'LLD-Master-Recovery.lldkey',filters:[{name:'LLD recovery',extensions:['lldkey']}]});if(result.canceled)return {message:'Save cancelled. Recovery is not verified.'};await fs.writeFile(result.filePath,text,{flag:'wx',mode:0o600});return {message:'Encrypted recovery file saved. Reenter the password and reopen this file to test recovery.'};},verify:async p=>{const text=await chooseFile();return text===null?{message:'Recovery check cancelled.'}:vault.verify(text,p);},restore:async p=>{const text=await chooseFile();return text===null?{message:'Recovery cancelled.'}:vault.restore(text,p);}};
 for(const [action,run] of Object.entries(actions))ipcMain.handle('key-setup:'+action,async(event,arg)=>{
  if(!win||event.sender!==win.webContents||event.senderFrame!==win.webContents.mainFrame||event.senderFrame.url!=='lld-keys://setup/setup.html')throw Error('Untrusted setup request');
  if(busy)return {ok:false,error:'A key operation is already running.'};busy=true;
  try{if(['create','unlock','verify','restore'].includes(action)&&typeof arg!=='string')throw Error('Enter a recovery password');return {ok:true,value:await run(arg)};}catch(e){return {ok:false,error: e.code==='EEXIST'?'That file already exists. Choose a new filename; existing keys are never overwritten.':/authenticate|bad decrypt|Unsupported state/.test(e.message)?'Recovery failed. Check the password and recovery file.':e.message};}finally{busy=false;if(!win)vault.lock();}
 });
 powerMonitor.on('lock-screen',()=>vault.lock());powerMonitor.on('suspend',()=>vault.lock());app.on('before-quit',()=>vault.lock());
 return function open(){if(win){win.show();win.focus();return;}win=new BrowserWindow({width:880,height:940,minWidth:540,minHeight:700,title:'Master key preparation',autoHideMenuBar:true,webPreferences:{session:ses,preload:path.join(__dirname,'preload.cjs'),sandbox:true,nodeIntegration:false,contextIsolation:true,webSecurity:true,devTools:false,webviewTag:false}});win.webContents.setWindowOpenHandler(()=>({action:'deny'}));for(const event of ['will-navigate','will-redirect','will-attach-webview'])win.webContents.on(event,e=>e.preventDefault());win.on('closed',()=>{vault.lock();win=null;});win.loadURL('lld-keys://setup/setup.html');};
}
module.exports={register};
