const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs/promises');const os=require('node:os');const path=require('node:path');const c=require('../key-setup/crypto.cjs');const {Vault}=require('../key-setup/vault.cjs');
const password='SYNTHETIC test only recovery phrase 12345';
test('key recovery, corruption rejection, wrong-password rejection, identity and KDF binding',async()=>{
 const original=await c.create(password),text=JSON.stringify(original.bundle);assert(!text.includes('PRIVATE KEY'));assert(!text.includes(password));const restored=await c.recover(text,password);assert.equal(restored.fingerprint,original.fingerprint);assert(c.proof(restored.privateKey));
 await assert.rejects(c.recover(text,'Incorrect synthetic recovery phrase!'));
 for(const field of ['iv','tag','ciphertext']){const b=structuredClone(original.bundle),v=Buffer.from(b[field],'base64');v[0]^=1;b[field]=v.toString('base64');await assert.rejects(c.recover(JSON.stringify(b),password));}
 for(const update of [{project:'other'},{owner:'other'},{kdf:{name:'scrypt',N:2**25,r:8,p:1}}])assert.throws(()=>c.parse(JSON.stringify({...original.bundle,...update})));
 await assert.rejects(c.create('short'));assert.throws(()=>c.parse('x'.repeat(32769)));
});
test('vault lifecycle, no silent replacement, recovery proof and locked state; mocked OS boundary',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'lld-synthetic-'));
 const storage={isAsyncEncryptionAvailable:async()=>true,encryptStringAsync:async value=>Buffer.from(value),decryptStringAsync:async value=>({result:value.toString()})};
 const vault=new Vault(path.join(dir,'first.bin'),storage),recovered=new Vault(path.join(dir,'second.bin'),storage);
 try{
  assert.equal((await vault.status()).exists,false);await vault.create(password);assert.equal((await vault.status()).verified,false);const backup=await vault.backup();assert(!backup.includes('PRIVATE KEY'));
  await assert.rejects(vault.create(password));await assert.rejects(vault.restore(backup,password));
  vault.lock();assert.equal((await vault.status()).unlocked,false);await assert.rejects(vault.unlock('Incorrect synthetic recovery phrase!'));assert.equal((await vault.status()).unlocked,false);
  await vault.verify(backup,password);assert.equal((await vault.status()).verified,true);await recovered.restore(backup,password);assert.equal((await recovered.status()).fingerprint,(await vault.status()).fingerprint);
  const foreign=await c.create(password);await assert.rejects(vault.verify(JSON.stringify(foreign.bundle),password),/different key/);
  vault.lock();const pending=vault.unlock(password);vault.lock();await pending;assert.equal((await vault.status()).unlocked,false,'a lock during an operation must prevail');
  const unavailable=new Vault(path.join(dir,'third.bin'),{isAsyncEncryptionAvailable:async()=>false});assert.equal((await unavailable.status()).available,false);
 }finally{vault.lock();recovered.lock();await fs.rm(dir,{recursive:true,force:true});}
});
