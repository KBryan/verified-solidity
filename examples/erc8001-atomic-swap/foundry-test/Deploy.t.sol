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
    function warp(uint256) external;
}

// The adapter's own entry points, called directly (not through Reach) to
// simulate third parties front-running or executing out of band.
interface IAdapter {
    function proposeSwap(
        uint256 expiry, uint256 nonce, address partyA, address partyB,
        address tokenA, uint256 amountA, address tokenB, uint256 amountB,
        bytes calldata signatureA
    ) external returns (bytes32);
    function executeSwap(bytes32 intentHash, address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        external returns (bool);
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

    uint256 constant AMOUNT_A = 100e18;
    uint256 constant AMOUNT_B = 5e16;

    // One swap's worth of state, threaded through the step helpers below.
    struct Ctx {
        uint256 alicePk;
        address alice;
        uint256 bobPk;
        address bob;
        MockERC20 tokenA;
        MockERC20 tokenB;
        ReachContract c;
        address companion;
        uint64 expiryA;
        uint64 nonceA;
        bytes32 intentStructHash;
        bytes sigA;
    }

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

    // Two fixed keys, assigned so Alice's address is lower or higher than
    // Bob's. The adapter used to require partyA < partyB, which stalled the
    // swap for about half of all address pairs; both orders must work.
    function setUpSwap(bool aliceLower) internal returns (Ctx memory x) {
        uint256 pkX = 0xA11CE;
        uint256 pkY = 0xB0B;
        address addrX = vm.addr(pkX);
        address addrY = vm.addr(pkY);
        bool xLower = addrX < addrY;
        (x.alicePk, x.alice, x.bobPk, x.bob) =
            (xLower == aliceLower) ? (pkX, addrX, pkY, addrY) : (pkY, addrY, pkX, addrX);
        require((x.alice < x.bob) == aliceLower, "key ordering setup");

        x.tokenA = new MockERC20();
        x.tokenB = new MockERC20();
        x.tokenA.mint(x.alice, AMOUNT_A);
        x.tokenB.mint(x.bob, AMOUNT_B);

        // Step 1 (constructor): Alice deploys, publishing the swap terms.
        vm.prank(x.alice);
        x.c = new ReachContract(T0(0, payable(x.bob), payable(address(x.tokenA)), AMOUNT_A, payable(address(x.tokenB)), AMOUNT_B));
        require(address(x.c).code.length > 0, "no code at deployed address");

        // Step 2: Alice's second publish deploys the AtomicSwapReachAdapter.
        vm.prank(x.alice);
        x.c._reachp_1(T2(0));
        x.companion = computeCreateAddress(address(x.c), 1);
        require(x.companion.code.length > 0, "companion not deployed");

        // Alice signs the AgentIntent (real EIP-712 digest, real ECDSA
        // signature). Participants are sorted ascending, as ERC8001 requires
        // and as the adapter builds them.
        IERC8001Constants k = IERC8001Constants(x.companion);
        bytes32 payloadHash = buildPayloadHash(k.SWAP_TYPE(), address(x.tokenA), AMOUNT_A, address(x.tokenB), AMOUNT_B);
        x.expiryA = uint64(block.timestamp + 1 hours);
        x.nonceA = 1;
        address[] memory participants = new address[](2);
        (participants[0], participants[1]) = x.alice < x.bob ? (x.alice, x.bob) : (x.bob, x.alice);
        x.intentStructHash = hashIntent(
            k.AGENT_INTENT_TYPEHASH(), payloadHash, x.expiryA, x.nonceA, x.alice, k.SWAP_TYPE(), participants);
        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(x.alicePk, typedDataHash(k.DOMAIN_SEPARATOR(), x.intentStructHash));
        x.sigA = abi.encodePacked(rA, sA, vA);

        vm.prank(x.alice);
        x.tokenA.approve(x.companion, AMOUNT_A);
    }

    // Step 3: Alice publishes the signed intent; the consensus step calls proposeSwap.
    function propose(Ctx memory x) internal {
        vm.prank(x.alice);
        x.c._reachp_2(T4(0, x.expiryA, x.nonceA, x.sigA));
    }

    // Step 4 (out of band, not through Reach -- see header comment): Bob
    // signs the AcceptanceAttestation and calls acceptCoordination on the
    // companion directly, so msg.sender == attestation.participant, then
    // approves the adapter for tokenB.
    function accept(Ctx memory x) internal {
        IERC8001Constants k = IERC8001Constants(x.companion);
        uint64 expiryB = uint64(block.timestamp + 1 hours);
        // attestation.intentHash is the intent's *struct* hash (per
        // IERC8001 docs: "getIntentHash(intent) -- the struct hash, not the
        // digest"), i.e. intentStructHash, not the EIP-712 digest we signed.
        bytes32 acceptStructHash = hashAttestation(
            k.ACCEPTANCE_TYPEHASH(), x.intentStructHash, x.bob, 1, expiryB, bytes32(0));
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(x.bobPk, typedDataHash(k.DOMAIN_SEPARATOR(), acceptStructHash));

        vm.prank(x.bob);
        bool allAccepted = IERC8001Accept(x.companion).acceptCoordination(
            x.intentStructHash,
            AcceptanceAttestation({
                intentHash: x.intentStructHash,
                participant: x.bob,
                nonce: 1,
                expiry: expiryB,
                conditionsHash: bytes32(0),
                signature: abi.encodePacked(rB, sB, vB)
            }));
        require(allAccepted, "accept did not complete coordination");

        vm.prank(x.bob);
        x.tokenB.approve(x.companion, AMOUNT_B);
    }

    // Step 5: Bob publishes into Reach again; the consensus step calls executeSwap.
    function execute(Ctx memory x) internal {
        vm.prank(x.bob);
        x.c._reachp_3(T2(0));
    }

    function requireSwapped(Ctx memory x) internal view {
        require(x.tokenA.balanceOf(x.bob) == AMOUNT_A, "tokenA not delivered to bob");
        require(x.tokenB.balanceOf(x.alice) == AMOUNT_B, "tokenB not delivered to alice");
        require(x.tokenA.balanceOf(x.alice) == 0, "alice still holds tokenA");
        require(x.tokenB.balanceOf(x.bob) == 0, "bob still holds tokenB");
    }

    function requireUnswapped(Ctx memory x) internal view {
        require(x.tokenA.balanceOf(x.alice) == AMOUNT_A, "alice lost tokenA");
        require(x.tokenB.balanceOf(x.bob) == AMOUNT_B, "bob lost tokenB");
    }

    function test_roundtrip_aliceLower() public {
        Ctx memory x = setUpSwap(true);
        propose(x);
        accept(x);
        execute(x);
        requireSwapped(x);
    }

    function test_roundtrip_aliceHigher() public {
        Ctx memory x = setUpSwap(false);
        propose(x);
        accept(x);
        execute(x);
        requireSwapped(x);
    }

    // A third party replays Alice's public signature into the adapter before
    // her Reach step lands; the Reach step must still succeed.
    function test_frontRunProposeDoesNotStall() public {
        Ctx memory x = setUpSwap(true);
        vm.prank(address(0xBEEF));
        IAdapter(x.companion).proposeSwap(
            x.expiryA, x.nonceA, x.alice, x.bob,
            address(x.tokenA), AMOUNT_A, address(x.tokenB), AMOUNT_B, x.sigA);
        propose(x);
        accept(x);
        execute(x);
        requireSwapped(x);
    }

    // A third party executes the swap directly on the adapter; Bob's Reach
    // step must still complete instead of reverting forever.
    function test_directExecutionDoesNotStall() public {
        Ctx memory x = setUpSwap(false);
        propose(x);
        accept(x);
        vm.prank(address(0xBEEF));
        require(
            IAdapter(x.companion).executeSwap(x.intentStructHash, address(x.tokenA), AMOUNT_A, address(x.tokenB), AMOUNT_B),
            "direct execution failed");
        execute(x);
        requireSwapped(x);
    }

    // Bob never accepts; once the intent expires, Bob's Reach step finishes
    // the program without moving any tokens.
    function test_expiredSwapFinishesWithoutTransfer() public {
        Ctx memory x = setUpSwap(true);
        propose(x);
        vm.warp(uint256(x.expiryA) + 1);
        execute(x);
        requireUnswapped(x);
    }

    // OpenZeppelin < 4.7.3 ECDSA.recover(bytes32, bytes) also accepted the
    // 64-byte EIP-2098 compact form of a signature (CVE-2022-35961), so one
    // signature had two valid encodings. The vendored 4.7.3 ECDSA accepts
    // only the 65-byte form: the compact encoding of Alice's valid
    // signature must be rejected.
    function test_compactSignatureRejected() public {
        Ctx memory x = setUpSwap(true);
        bytes32 r;
        bytes32 s_;
        uint8 v;
        bytes memory sig = x.sigA;
        assembly {
            r := mload(add(sig, 0x20))
            s_ := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        bytes32 vs = bytes32(uint256(s_) | (uint256(v - 27) << 255));
        bytes memory compact = abi.encodePacked(r, vs);
        require(compact.length == 64, "compact encoding");
        (bool ok, ) = x.companion.call(abi.encodeCall(IAdapter.proposeSwap, (
            x.expiryA, x.nonceA, x.alice, x.bob,
            address(x.tokenA), AMOUNT_A, address(x.tokenB), AMOUNT_B, compact)));
        require(!ok, "compact signature accepted");
        // The canonical 65-byte signature still works.
        propose(x);
        accept(x);
        execute(x);
        requireSwapped(x);
    }

    // The final step is bound to partyB; nobody else may drive it.
    function test_onlyPartyBCanExecute() public {
        Ctx memory x = setUpSwap(true);
        propose(x);
        accept(x);
        vm.prank(address(0xBEEF));
        (bool ok, ) = address(x.c).call(abi.encodeCall(ReachContract._reachp_3, (T2(0))));
        require(!ok, "non-partyB caller drove the final step");
        execute(x);
        requireSwapped(x);
    }
}
