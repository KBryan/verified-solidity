// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./token/ERC1155/ERC1155.sol";

// A hand-written companion contract wrapping OpenZeppelin's ERC1155. `reach
// sol` runs solc's SMTChecker (CHC engine) over this file plus its full
// import closure and refuses to emit artifacts unless every `assert` (and
// the automatic overflow/underflow/division checks) is proven, or the check
// level is explicitly lowered via --companion-check.
//
// `admin` is fixed to the deployer, which is the Reach-generated contract
// itself (Reach deploys this via `new Contract(...)`) -- so mint/burn are
// only reachable through the paired Reach consensus program, not by
// arbitrary externally-owned accounts.
contract ERC1155Wrapped is ERC1155 {
  address public immutable admin;

  constructor(string memory uri_) ERC1155(uri_) {
    admin = msg.sender;
  }

  function mint(address to, uint256 id, uint256 amount, bytes memory data) external {
    require(msg.sender == admin);
    _mint(to, id, amount, data);
  }

  function burn(address from, uint256 id, uint256 amount) external {
    require(msg.sender == admin || isApprovedForAll(from, msg.sender) || from == msg.sender);
    _burn(from, id, amount);
  }
}
