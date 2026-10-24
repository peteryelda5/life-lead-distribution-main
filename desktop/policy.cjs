const supabaseHost = 'yfuuigykpihoetgaefmu.supabase.co';
function assetPath(raw, manifest) {
  try {
    const url = new URL(raw);
    if (url.protocol !== 'lld:' || url.host !== 'portal' || url.username || url.password || url.search) return null;
    const pathname = url.pathname === '/' ? '/index.html' : url.pathname;
    return manifest.files.includes(pathname) ? pathname : null;
  } catch { return null; }
}
function allowedRequest(raw, resourceType, manifest) {
  try {
    const url = new URL(raw);
    if (assetPath(raw, manifest)) return true;
    return ['https:', 'wss:'].includes(url.protocol) && url.host === supabaseHost && !url.username && !url.password && ['xhr', 'webSocket'].includes(resourceType);
  } catch { return false; }
}
module.exports = { assetPath, allowedRequest };
