const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { assetPath, allowedRequest } = require('../policy.cjs');
const manifest = require('../ui/manifest.json');
const root = path.resolve(__dirname, '../..');
test('UI and workflows are copied intact; only SDK location changes', () => {
  const original = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  assert.equal(fs.readFileSync(path.join(root, 'desktop/ui/index.html'), 'utf8'), original.replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2', '/vendor/supabase.js'));
  for (const file of ['team-leaders.js', 'corporate-blue.css', 'dashboard.js', 'dashboard.css']) assert.equal(fs.readFileSync(path.join(root, file), 'utf8'), fs.readFileSync(path.join(root, 'desktop/ui', file), 'utf8'));
});
test('only exact bundled routes are served', () => {
  assert.equal(assetPath('lld://portal/', manifest), '/index.html');
  for (const url of ['lld://portal/main.cjs', 'lld://portal/../main.cjs', 'lld://portal/%2e%2e/main.cjs', 'lld://portal/ui/manifest.json', 'lld://evil/index.html', 'lld://portal/index.html?remote=1', 'file:///etc/passwd']) assert.equal(assetPath(url, manifest), null);
});
test('blocks remote code and exfiltration destinations; permits Supabase API only', () => {
  assert(allowedRequest('https://yfuuigykpihoetgaefmu.supabase.co/auth/v1/token', 'xhr', manifest));
  assert(!allowedRequest('https://yfuuigykpihoetgaefmu.supabase.co/code.js', 'script', manifest));
  for (const url of ['https://evil.example/leads', 'http://yfuuigykpihoetgaefmu.supabase.co', 'https://yfuuigykpihoetgaefmu.supabase.co.evil.example', 'https://yfuuigykpihoetgaefmu.supabase.co:444', 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2']) assert(!allowedRequest(url, 'xhr', manifest));
});
test('CSP authorizes exact inline scripts and asset hashes match package', () => {
  const html = fs.readFileSync(path.join(root, 'desktop/ui/index.html'), 'utf8');
  for (const match of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) assert(manifest.csp.includes("'sha256-" + createHash('sha256').update(match[1]).digest('base64') + "'"));
  assert(!manifest.csp.includes('unsafe-eval'));
  assert(!manifest.csp.match(/script-src[^;]*unsafe-inline/));
  for (const [file, hash] of Object.entries(manifest.hashes)) assert.equal(createHash('sha256').update(fs.readFileSync(path.join(root, 'desktop/ui', file))).digest('hex'), hash);
});
