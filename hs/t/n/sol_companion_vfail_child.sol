// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// A companion contract with a violable assert: SMTChecker finds the
// counterexample (x = 42) and the --sol compile must die without artifacts.
contract Bad {
  function f(uint256 x) external pure returns (uint256) {
    assert(x != 42);
    return x;
  }
}
