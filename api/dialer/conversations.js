'use strict';
module.exports=require('../../lib/dialer-full').endpoint(require('../../lib/dialer-conversations').action);
module.exports.config={maxDuration:60};
