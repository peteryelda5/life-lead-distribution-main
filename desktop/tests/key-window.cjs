const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path'),{createRequire}=require('node:module');
test('key IPC rejects portal windows, remote frames, subframes and closed windows',async()=>{
 const handlers=new Map(),routes=new Map();let win;
 class Window{constructor(){win=this;this.webContents={mainFrame:{url:'lld-keys://setup/setup.html'},setWindowOpenHandler(){},on(){}};this.events={};}on(name,fn){this.events[name]=fn;}loadURL(){}show(){}focus(){}}
 const fake={app:{getPath:()=>'/tmp/lld-no-key',on(){}},BrowserWindow:Window,session:{fromPartition:()=>({setPermissionRequestHandler(){},setPermissionCheckHandler(){},webRequest:{onBeforeRequest(){}},on(){},protocol:{handle:(s,f)=>routes.set(s,f)}})},ipcMain:{handle:(key,fn)=>handlers.set(key,fn)},dialog:{},safeStorage:{isAsyncEncryptionAvailable:async()=>false},powerMonitor:{on(){}}};
 const requireLocal=createRequire(path.resolve(__dirname,'../key-setup/window.cjs'));
 const context={require:name=>name==='electron'?fake:requireLocal(name),module:{exports:{}},__dirname:path.resolve(__dirname,'../key-setup'),process:{platform:'win32'},URL,Response};
 vm.runInNewContext(fs.readFileSync(path.resolve(__dirname,'../key-setup/window.cjs'),'utf8'),context);
 const open=context.module.exports.register();open();const invoke=handlers.get('key-setup:status');const valid={sender:win.webContents,senderFrame:win.webContents.mainFrame};assert.equal((await invoke(valid)).ok,true);
 await assert.rejects(invoke({...valid,sender:{}}),/Untrusted/);
 await assert.rejects(invoke({...valid,senderFrame:{url:'lld-keys://setup/setup.html'}}),/Untrusted/);
 win.webContents.mainFrame.url='lld://portal/index.html';await assert.rejects(invoke(valid),/Untrusted/);win.webContents.mainFrame.url='lld-keys://setup/setup.html';
 win.events.closed();await assert.rejects(invoke(valid),/Untrusted/);
 const route=routes.get('lld-keys');assert.equal((await route({url:'lld-keys://setup/crypto.cjs',method:'GET'})).status,404);
});
