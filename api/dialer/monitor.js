'use strict';
module.exports=require('../../lib/dialer-full').endpoint(require('../../lib/dialer-monitor').action);
module.exports.config={maxDuration:60};
