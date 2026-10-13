'use strict';
module.exports=require('../../lib/dialer-full').endpoint(require('../../lib/dialer-parallel').action);
module.exports.config={maxDuration:60};
