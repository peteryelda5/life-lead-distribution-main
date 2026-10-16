/** Experimental client-side primitive. Not wired to production or a trusted key directory. */
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const suite = 'LLD-A256GCM-RSAOAEP256-v1';
function contextBytes(context) {
  if (!context || Object.keys(context).sort().join(',') !== 'division,project,record,version' ||
      context.project !== 'yfuuigykpihoetgaefmu' ||
      !['owner', 'vivid_life', 'legacy_life'].includes(context.division) ||
      !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(context.record) || context.version !== 1) {
    throw new Error('Invalid lead encryption context');
  }
  return encoder.encode(JSON.stringify([suite, context.project, context.division, context.record, context.version]));
}
function encode(bytes) {
  let binary = '';
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function decode(value) {
  if (typeof value !== 'string') throw new Error('Invalid ciphertext encoding');
  return Uint8Array.from(atob(value), char => char.charCodeAt(0));
}
function checkKey(key, type, usage) {
  if (!key || key.type !== type || key.algorithm?.name !== 'RSA-OAEP' ||
      key.algorithm.hash?.name !== 'SHA-256' || key.algorithm.modulusLength < 3072 || !key.usages.includes(usage)) {
    throw new Error('A 3072-bit or stronger RSA-OAEP SHA-256 key is required');
  }
}
export async function publicKeyFingerprint(publicKey) {
  checkKey(publicKey, 'public', 'encrypt');
  return encode(await crypto.subtle.digest('SHA-256', await crypto.subtle.exportKey('spki', publicKey)));
}
/** trustedFingerprints MUST originate outside the untrusted database response. */
export async function encryptLead(payload, context, recipients, trustedFingerprints, masterId) {
  const aad = contextBytes(context);
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('Expected a lead payload');
  if (!Array.isArray(recipients) || recipients.length < 1 || recipients.length > 32 ||
      new Set(recipients.map(r => r.id)).size !== recipients.length ||
      !recipients.some(r => r.id === masterId)) throw new Error('Unique recipients including Master are required');
  for (const recipient of recipients) {
    if (typeof recipient.id !== 'string' || !recipient.id ||
        await publicKeyFingerprint(recipient.publicKey) !== trustedFingerprints.get(recipient.id)) {
      throw new Error('Untrusted recipient key');
    }
  }
  const rawKey = crypto.getRandomValues(new Uint8Array(32));
  try {
    const key = await crypto.subtle.importKey('raw', rawKey, 'AES-GCM', false, ['encrypt']);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad, tagLength: 128 }, key, encoder.encode(JSON.stringify(payload)));
    const wrappedKeys = [];
    for (const recipient of recipients) {
      const label = encoder.encode(JSON.stringify([encode(aad), recipient.id]));
      wrappedKeys.push({ id: recipient.id, key: encode(await crypto.subtle.encrypt({ name: 'RSA-OAEP', label }, recipient.publicKey, rawKey)) });
    }
    return { suite, context: { ...context }, iv: encode(iv), ciphertext: encode(ciphertext), wrappedKeys };
  } finally { rawKey.fill(0); }
}
/** expectedContext comes from the requested record, never from the envelope itself. */
export async function decryptLead(envelope, expectedContext, recipientId, privateKey) {
  const aad = contextBytes(expectedContext);
  if (envelope?.suite !== suite || encode(contextBytes(envelope.context)) !== encode(aad)) throw new Error('Lead context mismatch');
  checkKey(privateKey, 'private', 'decrypt');
  if (!Array.isArray(envelope.wrappedKeys)) throw new Error('Invalid key envelope');
  const entries = envelope.wrappedKeys.filter(item => item.id === recipientId);
  if (entries.length !== 1) throw new Error('Recipient key unavailable');
  const iv = decode(envelope.iv);
  if (iv.length !== 12) throw new Error('Invalid IV');
  const label = encoder.encode(JSON.stringify([encode(aad), recipientId]));
  const rawKey = new Uint8Array(await crypto.subtle.decrypt({ name: 'RSA-OAEP', label }, privateKey, decode(entries[0].key)));
  try {
    if (rawKey.length !== 32) throw new Error('Invalid data key');
    const key = await crypto.subtle.importKey('raw', rawKey, 'AES-GCM', false, ['decrypt']);
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad, tagLength: 128 }, key, decode(envelope.ciphertext));
    return JSON.parse(decoder.decode(plaintext));
  } finally { rawKey.fill(0); }
}
