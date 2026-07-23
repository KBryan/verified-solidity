// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

// Deploys the Reach-emitted contract (copied into src/ by run.sh) and runs
// the full ERC-8001 round trip -- Alice deploys the AtomicSwapReachAdapter
// companion and, through Reach, signs+publishes an AgentIntent (real
// EIP-712 digest, real ECDSA signature via vm.sign). Bob then signs an
// AcceptanceAttestation the same way and calls acceptCoordination on the
// companion DIRECTLY (not through Reach -- see index.rsh's header comment
// for why acceptCoordination's msg.sender check makes that impossible for
// any remote()-mediated call). Reach then orchestrates execute, against two
// minimal mock ERC20 tokens, confirming the swap actually moves both.
//
// This test computes EIP-712 digests itself (domain separator + struct
// hashes, matching ERC8001.sol's _hashIntent/_hashAttestation/EIP712
// exactly) and signs them with vm.sign against known test private keys.
// It does not exercise an ethers.js/viem signTypedData call -- see
// index.rsh's header comment for why that's out of scope here. No
// forge-std dependency: cheatcodes are reached via the standard VM address
// directly, same convention as erc1155-companion's Deploy.t.sol avoiding
// external dependencies.
import {ReachContract, T0, T2, T4} from "../src/index.main.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function prank(address) external;
}

interface IERC8001Constants {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function AGENT_INTENT_TYPEHASH() external view returns (bytes32);
    function ACCEPTANCE_TYPEHASH() external view returns (bytes32);
    function SWAP_TYPE() external view returns (bytes32);
}

// Matches IERC8001.AcceptanceAttestation exactly (field order/types), so
// this test can call acceptCoordination directly with real struct calldata
// -- the same call shape any plain Solidity or ethers.js/viem caller would
// use, distinct from what Reach's remote() can express.
struct AcceptanceAttestation {
    bytes32 intentHash;
    address participant;
    uint64 nonce;
    uint64 expiry;
    bytes32 conditionsHash;
    bytes signature;
}

interface IERC8001Accept {
    function acceptCoordination(bytes32 intentHash, AcceptanceAttestation calldata attestation)
        external returns (bool allAccepted);
}

// Minimal ERC20 mock: just enough surface (mint/approve/transferFrom/
// balanceOf) for AtomicSwap's safeTransferFrom calls to succeed.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DeployTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce >= 1 && nonce <= 127, "nonce out of supported range");
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)
        )))));
    }

    function hashIntent(
        bytes32 typehash, bytes32 payloadHash, uint64 expiry, uint64 nonce,
        address agentId, bytes32 coordinationType, address[] memory participants
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            typehash, payloadHash, expiry, nonce, agentId, coordinationType,
            uint256(0), keccak256(abi.encodePacked(participants))
        ));
    }

    function hashAttestation(
        bytes32 typehash, bytes32 intentHash, address participant,
        uint64 nonce, uint64 expiry, bytes32 conditionsHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(typehash, intentHash, participant, nonce, expiry, conditionsHash));
    }

    function typedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, structHash));
    }

    function buildPayloadHash(bytes32 swapType, address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        internal pure returns (bytes32)
    {
        bytes memory coordinationData = abi.encode(tokenA, amountA, tokenB, amountB);
        return keccak256(abi.encode(
            bytes32(0), swapType, keccak256(coordinationData), bytes32(0), uint256(0), keccak256("")
        ));
    }

    function test_roundtrip() public {
        // Pick two private keys and assign alice/bob so alice's address is
        // strictly smaller -- ERC-8001 requires participants strictly
        // ascending by uint160(address), and AtomicSwapReachAdapter
        // enforces partyA (agentId, always Alice here) < partyB.
        uint256 pkX = 0xA11CE;
        uint256 pkY = 0xB0B;
        address addrX = vm.addr(pkX);
        address addrY = vm.addr(pkY);
        (uint256 alicePk, address alice, uint256 bobPk, address bob) =
            addrX < addrY ? (pkX, addrX, pkY, addrY) : (pkY, addrY, pkX, addrX);

        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        uint256 amountA = 100e18;
        uint256 amountB = 5e16;
        tokenA.mint(alice, amountA);
        tokenB.mint(bob, amountB);

        // Step 1 (constructor): Alice deploys, publishing the swap terms.
        vm.prank(alice);
        ReachContract c = new ReachContract(T0(0, payable(bob), payable(address(tokenA)), amountA, payable(address(tokenB)), amountB));
        require(address(c).code.length > 0, "no code at deployed address");

        // Step 2: Alice's second publish deploys the AtomicSwapReachAdapter.
        vm.prank(alice);
        c._reachp_1(T2(0));
        address companion = computeCreateAddress(address(c), 1);
        require(companion.code.length > 0, "companion not deployed");

        IERC8001Constants k = IERC8001Constants(companion);
        bytes32 swapType = k.SWAP_TYPE();
        bytes32 payloadHash = buildPayloadHash(swapType, address(tokenA), amountA, address(tokenB), amountB);

        // Step 3: Alice signs the AgentIntent (real EIP-712 digest, real
        // ECDSA signature) and approves the adapter for tokenA, then
        // publishes -- the consensus step calls proposeSwap.
        uint64 expiryA = uint64(block.timestamp + 1 hours);
        uint64 nonceA = 1;
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;
        bytes32 intentStructHash = hashIntent(
            k.AGENT_INTENT_TYPEHASH(), payloadHash, expiryA, nonceA, alice, swapType, participants);
        bytes32 intentDigest = typedDataHash(k.DOMAIN_SEPARATOR(), intentStructHash);
        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(alicePk, intentDigest);
        bytes memory sigA = abi.encodePacked(rA, sA, vA);

        vm.prank(alice);
        tokenA.approve(companion, amountA);

        vm.prank(alice);
        c._reachp_2(T4(0, expiryA, nonceA, sigA));

        // Step 4 (out of band, not through Reach -- see header comment):
        // Bob signs the AcceptanceAttestation and calls acceptCoordination
        // on the companion directly himself, so msg.sender ==
        // attestation.participant as ERC8001 requires.
        uint64 expiryB = uint64(block.timestamp + 1 hours);
        uint64 nonceB = 1;
        // attestation.intentHash is the intent's *struct* hash (per
        // IERC8001 docs: "getIntentHash(intent) -- the struct hash, not the
        // digest"), i.e. intentStructHash, not the EIP-712 digest we signed.
        bytes32 acceptStructHash = hashAttestation(
            k.ACCEPTANCE_TYPEHASH(), intentStructHash, bob, nonceB, expiryB, bytes32(0));
        bytes32 acceptDigest = typedDataHash(k.DOMAIN_SEPARATOR(), acceptStructHash);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(bobPk, acceptDigest);
        bytes memory sigB = abi.encodePacked(rB, sB, vB);

        vm.prank(bob);
        bool allAccepted = IERC8001Accept(companion).acceptCoordination(
            intentStructHash,
            AcceptanceAttestation({
                intentHash: intentStructHash,
                participant: bob,
                nonce: nonceB,
                expiry: expiryB,
                conditionsHash: bytes32(0),
                signature: sigB
            }));
        require(allAccepted, "accept did not complete coordination");

        // Step 5: Bob approves the adapter for tokenB, then publishes into
        // Reach again -- the consensus step calls executeSwap.
        vm.prank(bob);
        tokenB.approve(companion, amountB);

        vm.prank(bob);
        c._reachp_3(T2(0));

        require(tokenA.balanceOf(bob) == amountA, "tokenA not delivered to bob");
        require(tokenB.balanceOf(alice) == amountB, "tokenB not delivered to alice");
        require(tokenA.balanceOf(alice) == 0, "alice still holds tokenA");
        require(tokenB.balanceOf(bob) == 0, "bob still holds tokenB");
    }
}
