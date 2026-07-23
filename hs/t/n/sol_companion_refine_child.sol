// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// SMTChecker-clean companion; the failure in this fixture comes from the
// Reach side violating the interface's Refine precondition.
contract Child {
  function f(uint256 x) external pure returns (uint256) {
    require(x < 1000);
    uint256 y = x + 1;
    assert(y > x);
    return y;
  }
}
