// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// A companion contract whose properties (the assert below, plus the
// automatic overflow checks) are all provable by solc's SMTChecker.
contract Child {
  function f(uint256 x) external pure returns (uint256) {
    require(x < 1000);
    uint256 y = x + 1;
    assert(y > x);
    return y;
  }
}
