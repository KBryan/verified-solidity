// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

// Deploys the Reach-emitted contract (copied into src/ by run.sh) and runs
// the full mint round trip: Admin deploys the ERC1155Wrapped companion,
// Recipient triggers mint(), then this test independently queries the
// companion's balanceOf to confirm the mint landed on-chain.
// No forge-std dependency: the companion's address is computed via the
// standard CREATE-at-nonce-1 formula (the companion is the only contract
// ReachContract ever creates), rather than captured via cheatcode log
// recording -- keeps the scratch project offline, same as
// verified-solidity-interop's Deploy.t.sol.
import {ReachContract, T0, T2} from "../src/index.main.sol";

interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract DeployTest {
    // ERC1155Wrapped.mint's `to` argument is msg.sender of the _reachp_2
    // call -- this contract itself. OZ's _mint does a safe-transfer
    // acceptance check on contract recipients, so this contract must
    // implement IERC1155Receiver or the mint reverts.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        // Valid only for nonce in [1, 127] (single-byte RLP encoding); the
        // companion is the first and only contract ReachContract creates,
        // so its creation nonce is always 1.
        require(nonce >= 1 && nonce <= 127, "nonce out of supported range");
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)
        )))));
    }

    function test_roundtrip() public {
        uint256 tokenId = 7;
        uint256 amount = 1000;

        // Step 1 (constructor): Admin publishes uri/tokenId/amount.
        ReachContract c = new ReachContract(T0(0, "https://example.test/{id}.json", tokenId, amount));
        require(address(c).code.length > 0, "no code at deployed address");

        // Step 2: Admin's second publish deploys the ERC1155Wrapped companion.
        c._reachp_1(T2(0));
        address companion = computeCreateAddress(address(c), 1);
        require(companion.code.length > 0, "companion not deployed");

        // Step 3: this contract acts as Recipient; msg.sender here becomes
        // the mint's `to` argument inside the generated contract.
        c._reachp_2(T2(0));

        uint256 bal = IERC1155Balance(companion).balanceOf(address(this), tokenId);
        require(bal == amount, "balance not minted");
    }
}
