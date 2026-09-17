'use strict';
const c = require('node:crypto');
const { promisify } = require('node:util');
const scrypt = promisify(c.scrypt), generate = promisify(c.generateKeyPair);
const PROJECT = 'yfuuigykpihoetgaefmu';
const OWNER = '8139e230-055d-4247-8133-684ed817b4fa';
const FORMAT = 'lld-master-recovery-v1';
const PARAMS = Object.freeze({ N: 131072, r: 8, p: 1 });
const aad = Buffer.from(JSON.stringify([FORMAT, PROJECT, OWNER]));
function passwordValid(password) {
  if (typeof password !== 'string' || password.length < 20 || password.length > 512 || password.trim().length < 20) throw Error('Use a recovery password of 20–512 characters. A long, unique phrase is best.');
}
function fingerprint(key) { return c.createHash('sha256').update(c.createPublicKey(key).export({type:'spki',format:'der'})).digest('hex'); }
function bytes(value, length) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw Error('Invalid recovery file');
  const result = Buffer.from(value, 'base64');
  if (result.toString('base64') !== value || (length && result.length !== length)) throw Error('Invalid recovery file');
  return result;
}
function parse(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > 32768) throw Error('Invalid recovery file');
  const bundle = JSON.parse(text);
  if (bundle.format !== FORMAT || bundle.project !== PROJECT || bundle.owner !== OWNER ||
      bundle.kdf?.name !== 'scrypt' || bundle.kdf.N !== PARAMS.N || bundle.kdf.r !== PARAMS.r || bundle.kdf.p !== PARAMS.p) throw Error('Unsupported recovery file');
  bytes(bundle.salt,32);bytes(bundle.iv,12);bytes(bundle.tag,16);
  if (bytes(bundle.ciphertext).length < 1024) throw Error('Invalid recovery file');
  return bundle;
}
async function derive(password,salt) { passwordValid(password);return scrypt(password,salt,32,{...PARAMS,maxmem:256*1024*1024}); }
async function create(password) {
  passwordValid(password);
  const pair = await generate('rsa',{modulusLength:3072,publicExponent:65537});
  const privateBytes = Buffer.from(pair.privateKey.export({type:'pkcs8',format:'pem'}));
  const salt=c.randomBytes(32),iv=c.randomBytes(12),key=await derive(password,salt);
  try {
    const cipher=c.createCipheriv('aes-256-gcm',key,iv);cipher.setAAD(aad);
    const ciphertext=Buffer.concat([cipher.update(privateBytes),cipher.final()]);
    const bundle={format:FORMAT,project:PROJECT,owner:OWNER,kdf:{name:'scrypt',...PARAMS},salt:salt.toString('base64'),iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),ciphertext:ciphertext.toString('base64')};
    return {bundle,privateKey:pair.privateKey,fingerprint:fingerprint(pair.privateKey)};
  } finally {privateBytes.fill(0);key.fill(0);}
}
async function recover(text,password) {
  const bundle=parse(text),key=await derive(password,bytes(bundle.salt,32));let plaintext;
  try {
    const decipher=c.createDecipheriv('aes-256-gcm',key,bytes(bundle.iv,12));decipher.setAAD(aad);decipher.setAuthTag(bytes(bundle.tag,16));
    plaintext=Buffer.concat([decipher.update(bytes(bundle.ciphertext)),decipher.final()]);
    const privateKey=c.createPrivateKey(plaintext);
    if(privateKey.asymmetricKeyType!=='rsa'||privateKey.asymmetricKeyDetails.modulusLength!==3072)throw Error('Invalid key type');
    return {bundle,privateKey,fingerprint:fingerprint(privateKey)};
  } finally {key.fill(0);if(plaintext)plaintext.fill(0);}
}
function proof(privateKey) {
  const secret=c.randomBytes(32);
  const encrypted=c.publicEncrypt({key:c.createPublicKey(privateKey),oaepHash:'sha256',padding:c.constants.RSA_PKCS1_OAEP_PADDING},secret);
  const recovered=c.privateDecrypt({key:privateKey,oaepHash:'sha256',padding:c.constants.RSA_PKCS1_OAEP_PADDING},encrypted);
  const ok=c.timingSafeEqual(secret,recovered);secret.fill(0);recovered.fill(0);if(!ok)throw Error('Recovery check failed');return true;
}
module.exports={create,recover,parse,proof,fingerprint,passwordValid};
