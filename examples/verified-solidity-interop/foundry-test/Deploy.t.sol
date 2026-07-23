// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

// Deploys the Reach-emitted contract (copied into src/ by run.sh) and runs
// the full escrow round trip, which internally deploys the hand-written
// Vault companion and calls its verified `net` function.
// No forge-std dependency: plain requires keep the scratch project offline.
import {ReachContract, T0, T2} from "../src/index.main.sol";

contract DeployTest {
    receive() external payable {}

    function test_roundtrip() public {
        // Deposit within the verified range [100, 1000000] wei.
        uint256 amt = 1000;
        ReachContract c = new ReachContract{value: amt}(T0(0, amt));
        require(address(c).code.length > 0, "no code at deployed address");
        require(address(c).balance == amt, "deposit not held by contract");

        // Second step: deploys Vault, computes net(amt), pays everything out.
        uint256 balBefore = address(this).balance;
        c._reachp_1(T2(0));
        require(address(c).balance == 0, "contract not drained");
        require(address(this).balance == balBefore + amt, "payout wrong");
    }
}
