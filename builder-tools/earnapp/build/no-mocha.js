// Stands in for mocha in the bundle: the client loads it at start-up for its
// self-test command, which this image doesn't ship.
'use strict';
module.exports = class Mocha {
    constructor(){ throw new Error('earnapp: self-tests are not included in this build'); }
};
