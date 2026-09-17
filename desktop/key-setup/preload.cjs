const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('keySetup',Object.freeze({
 status:()=>ipcRenderer.invoke('key-setup:status'),
 create:password=>ipcRenderer.invoke('key-setup:create',password),
 backup:()=>ipcRenderer.invoke('key-setup:backup'),
 verify:password=>ipcRenderer.invoke('key-setup:verify',password),
 restore:password=>ipcRenderer.invoke('key-setup:restore',password),
 unlock:password=>ipcRenderer.invoke('key-setup:unlock',password),
 lock:()=>ipcRenderer.invoke('key-setup:lock')
}));
