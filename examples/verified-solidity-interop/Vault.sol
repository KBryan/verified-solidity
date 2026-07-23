// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// A hand-written companion contract. Its properties are stated directly in
// Solidity as `assert`s; `reach sol` runs solc's SMTChecker (CHC engine)
// over this file and refuses to emit artifacts unless every assert (plus
// the automatic overflow/underflow/division checks) is proven or the check
// level is explicitly lowered.
contract Vault {
  // A 1% fee, defined for deposits in [100, 1000000] network-token units.
  function fee(uint256 amt) public pure returns (uint256 f) {
    require(amt >= 100 && amt <= 1000000);
    f = amt / 100;
    assert(f >= 1);
    assert(f <= amt);
  }

  // The amount paid out after the fee. The Reach program's interface for
  // this function declares the postcondition `n <= amt` (runtime-enforced
  // and assumed by Z3); the asserts below are proven by the SMTChecker.
  function net(uint256 amt) external pure returns (uint256 n) {
    uint256 f = fee(amt);
    n = amt - f;
    assert(n + f == amt);
    assert(n <= amt);
  }
}
