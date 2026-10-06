'use strict';
const assert=require('node:assert/strict');
const full=require('../lib/dialer-full');
const calls=[];
full.rpc=async(name,args)=>{calls.push({name,args});return name==='dialer_get_account'?{customer_id:'cus_owner'}:{subscription_status:'owner_exempt',paid_invoice:false};};
full.stripe=async()=>{throw Error('Owner flow must not contact Stripe');};
const billing=require('../lib/dialer-full-billing');
(async()=>{const owner={id:full.MASTER,live:true};const state=await billing.sync(owner);assert.equal(state.subscription_status,'owner_exempt');assert.deepEqual(calls.map(x=>x.name),['dialer_get_account','dialer_sync_master_access']);await assert.rejects(billing.checkout(owner),/free/);await assert.rejects(billing.portal(owner),/no Stripe subscription/);const before=calls.length;await billing.overage(owner,{});await billing.settleFinal(owner,{});assert.equal(calls.length,before);await assert.rejects(billing.sync({id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',live:true}),/must not contact Stripe/);await assert.rejects(billing.sync({id:full.MASTER,live:false}),/must not contact Stripe/);console.log('PASS: only live Master is exempt; checkout and portal blocked; no owner overage invoices; agents and test billing still use Stripe.');})().catch(e=>{console.error(e);process.exitCode=1;});
