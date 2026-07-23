// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8001} from "../ERC8001.sol";
import {IERC8001} from "../interfaces/IERC8001.sol";
import {IERC20} from "../../oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../oz/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AtomicSwap
 * @dev Hello World of ERC-8001: Trustless token swaps between two parties.
 *
 * How it works:
 * 1. Alice wants to swap 100 USDC for 0.05 WETH from Bob
 * 2. Alice proposes the swap (signs an intent specifying the terms)
 * 3. Bob reviews and accepts (signs an acceptance)
 * 4. Anyone can execute -> tokens swap atomically
 *
 * If either party doesn't sign, or the intent expires, nothing happens.
 * No intermediary. No trust required. Pure coordination.
 */
contract AtomicSwap is ERC8001 {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Swap terms encoded in coordinationData
    struct SwapTerms {
        address tokenA;  // Token Alice is offering
        uint256 amountA; // Amount Alice is offering
        address tokenB;  // Token Bob is offering
        uint256 amountB; // Amount Bob is offering
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Coordination type identifier for swaps
    bytes32 public constant SWAP_TYPE = keccak256("ATOMIC_SWAP_V1");

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event SwapExecuted(
        bytes32 indexed intentHash,
        address indexed partyA,
        address indexed partyB,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidSwapType();
    error InvalidParticipantCount();
    error InsufficientAllowance(address token, address owner, uint256 required);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() ERC8001() {}

    // ═══════════════════════════════════════════════════════════════════════════
    // EXECUTION HOOK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Execute the atomic swap.
     *      Both parties must have approved this contract for their tokens.
     */
    function _executeCoordinationHook(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata /* executionData */
    ) internal override returns (bool, bytes memory) {
        // Validate coordination type
        if (payload.coordinationType != SWAP_TYPE) {
            revert InvalidSwapType();
        }

        // Get participants from stored state (no longer in payload)
        CoordinationState storage coord = _getCoordination(intentHash);

        // Validate exactly 2 participants
        if (coord.participants.length != 2) {
            revert InvalidParticipantCount();
        }

        // Decode swap terms
        SwapTerms memory terms = abi.decode(payload.coordinationData, (SwapTerms));

        // Find proposer and acceptor in participants array
        address partyA = coord.proposer; // Proposer
        address partyB;
        if (coord.participants[0] == coord.proposer) {
            partyB = coord.participants[1];
        } else {
            partyB = coord.participants[0];
        }

        // Execute atomic swap:
        // 1. Transfer tokenA from partyA to partyB
        IERC20(terms.tokenA).safeTransferFrom(partyA, partyB, terms.amountA);

        // 2. Transfer tokenB from partyB to partyA
        IERC20(terms.tokenB).safeTransferFrom(partyB, partyA, terms.amountB);

        emit SwapExecuted(
            intentHash, partyA, partyB, terms.tokenA, terms.amountA, terms.tokenB, terms.amountB
        );

        return (true, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Encode swap terms for use in coordinationData.
     * @param tokenA Token the proposer is offering
     * @param amountA Amount the proposer is offering
     * @param tokenB Token the proposer wants in return
     * @param amountB Amount the proposer wants in return
     */
    function encodeSwapTerms(address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        external
        pure
        returns (bytes memory)
    {
        return
            abi.encode(
                SwapTerms({tokenA: tokenA, amountA: amountA, tokenB: tokenB, amountB: amountB})
            );
    }

    /**
     * @notice Decode swap terms from coordinationData.
     */
    function decodeSwapTerms(bytes calldata coordinationData)
        external
        pure
        returns (SwapTerms memory)
    {
        return abi.decode(coordinationData, (SwapTerms));
    }

    /**
     * @notice Check if both parties have sufficient allowances for a swap.
     * @param partyA First party (proposer)
     * @param partyB Second party (acceptor)
     * @param terms The swap terms to check
     */
    function checkAllowances(address partyA, address partyB, SwapTerms calldata terms)
        external
        view
        returns (bool partyAReady, bool partyBReady)
    {
        partyAReady = IERC20(terms.tokenA).allowance(partyA, address(this)) >= terms.amountA;
        partyBReady = IERC20(terms.tokenB).allowance(partyB, address(this)) >= terms.amountB;
    }
}
