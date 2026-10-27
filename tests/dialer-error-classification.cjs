'use strict';
const assert=require('node:assert/strict'),{errorKind}=require('../lib/dialer-full');
assert.equal(errorKind({name:'TimeoutError',message:'secret'}),'upstream_timeout');
assert.equal(errorKind({cause:{code:'ECONNRESET',message:'secret'}}),'upstream_network');
assert.equal(errorKind(new SyntaxError('private payload')),'invalid_upstream_json');
assert.equal(errorKind({status:409}),'handled');assert.equal(errorKind({code:'private value'}),'unexpected');
console.log('PASS: timeout, network and JSON failures classified without exposing raw errors.');
