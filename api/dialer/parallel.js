'use strict';
module.exports=require('../../lib/dialer-full').endpoint(require('../../lib/dialer-parallel').action,{onboardingCleanupActions:['stop']});
module.exports.config={maxDuration:60};
