const { app, BrowserWindow, protocol, session, dialog, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { assetPath, allowedRequest } = require('./policy.cjs');
const manifest = require('./ui/manifest.json');
app.setName('Life Lead Distribution Trial');
app.setPath('userData', path.join(app.getPath('appData'), 'Life Lead Distribution Trial'));
app.enableSandbox();
protocol.registerSchemesAsPrivileged([{ scheme: 'lld', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } }]);
let mainWindow;
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (mainWindow) { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.focus(); } });
  app.whenReady().then(async () => {
    Menu.setApplicationMenu(null);
    session.defaultSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
    session.defaultSession.setPermissionCheckHandler(() => false);
    session.defaultSession.webRequest.onBeforeRequest((details, callback) => callback({ cancel: !allowedRequest(details.url, details.resourceType, manifest) }));
    session.defaultSession.on('will-download', event => event.preventDefault());
    protocol.handle('lld', request => {
      const relative = assetPath(request.url, manifest);
      if (request.method !== 'GET' || !relative) return new Response('Not found', { status: 404 });
      const type = relative.endsWith('.png') ? 'image/png' : relative.endsWith('.html') ? 'text/html; charset=utf-8' : relative.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8';
      return new Response(fs.readFileSync(path.join(__dirname, 'ui', relative)), { headers: { 'Content-Type': type, 'Content-Security-Policy': manifest.csp, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store' } });
    });
    const answer = await dialog.showMessageBox({ type: 'info', title: 'Life Lead Distribution — trial', message: 'This trial connects to your existing live portal account.', detail: 'The interface is bundled on your computer. Lead edits, uploads and deletions affect your real account. New lead encryption is not enabled. This preview is unsigned and has no automatic updates. Choose Exit if you only wanted a demonstration with sample data.', buttons: ['Exit', 'Open my portal'], defaultId: 0, cancelId: 0, noLink: true });
    if (answer.response !== 1) { app.quit(); return; }
    mainWindow = new BrowserWindow({ width: 1440, height: 950, minWidth: 480, minHeight: 600, show: false, title: 'Life Lead Distribution — Trial', backgroundColor: '#f4f7fc', icon: path.join(__dirname, 'ui/assets/lld-icon-v1.png'), webPreferences: { nodeIntegration: false, nodeIntegrationInWorker: false, contextIsolation: true, sandbox: true, webSecurity: true, allowRunningInsecureContent: false, webviewTag: false, devTools: false } });
    mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    mainWindow.webContents.on('will-navigate', event => event.preventDefault());
    mainWindow.webContents.on('will-redirect', event => event.preventDefault());
    mainWindow.webContents.on('will-attach-webview', event => event.preventDefault());
    mainWindow.on('page-title-updated', event => event.preventDefault());
    mainWindow.once('ready-to-show', () => mainWindow.show());
    mainWindow.on('closed', () => { mainWindow = null; });
    await mainWindow.loadURL('lld://portal/index.html');
  }).catch(error => { dialog.showErrorBox('Could not open Life Lead Distribution', error.message); app.quit(); });
}
app.on('window-all-closed', () => app.quit());
