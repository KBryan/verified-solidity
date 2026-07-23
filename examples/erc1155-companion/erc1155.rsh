'reach 0.1';

// Reusable helper for the ERC1155Wrapped companion contract (ERC1155Wrapped.sol).
// `ContractCode`'s path resolves relative to *this* file, so any app that
// imports deployERC1155/ERC1155Interface from here gets correct path
// resolution regardless of where the importing .rsh lives, as long as it
// stays a relative sibling of this directory (the vendored OpenZeppelin
// tree -- token/, utils/ -- travels with erc1155.rsh, not with the importer).
//
// The vendored tree sits flat, directly alongside this file (not nested
// under a subdirectory) because Reach's real Solidity codegen path reads
// the ContractCode target under a synthetic source name with no directory
// component, so relative imports inside it resolve against the compiler's
// working directory, not against ERC1155Wrapped.sol's own location on disk.
// Nesting the vendored tree under a subfolder breaks import resolution in
// that path even though solc's standalone SMTChecker CLI (a separate code
// path, used only for the informational --companion-check analysis) has no
// such restriction.
//
// Scope (v1): single-id mint/burn/transfer/approval only. safeBatchTransferFrom
// and balanceOfBatch are NOT exposed -- Reach's Array(T,N) is fixed-length and
// has no dynamic-array type for non-byte elements, so Solidity's
// `uint256[]`/`address[]` batch parameters cannot be given a faithful
// `remote()` signature. Callers needing batch semantics must loop
// safeTransferFrom per id from the Reach side; note this is N separate calls,
// not one atomic batch call, so gas and atomicity differ from a real batch.

// Deploys a fresh ERC1155Wrapped companion with the given metadata URI
// (e.g. 'https://example.test/{id}.json'). The deploying contract becomes
// `admin` in the companion, so only it may mint/burn.
//
// ContractCode is constructed here, inside the function, rather than as a
// top-level export -- constructed at module-load time (before the
// importing app's setOptions({connectors: [...]}) has run) it defaults to
// checking every connector Reach knows about, not just the ones the app
// actually enables, and fails for connectors with no ETH/ALGO field given.
export const deployERC1155 = (uri_) => {
  const ERC1155Code = ContractCode({ ETH: 'ERC1155Wrapped.sol:ERC1155Wrapped' });
  const tokenNew = new Contract(ERC1155Code, {});
  return tokenNew(uri_);
};

// Wraps a deployed ERC1155Wrapped contract handle with its verified `remote`
// interface. Two calls carry a `Refine`:
//  - mint: precondition amount > 0 (nothing else is checkable client-side;
//    the admin-only `require` in Solidity is a runtime check, not proven here).
//  - safeTransferFrom: precondition from != to (a trivial, always-checkable
//    sanity condition; balance sufficiency is enforced by the companion at
//    runtime and is not proven by Z3, since the companion's storage is
//    outside the Reach verifier's model -- see vr_assumptions in the report).
// All other calls are unrefined Funs: their results are recorded as `havoc`
// in vr_assumptions, since there is no non-trivial postcondition to state.
export const ERC1155Interface = (ctc) => remote(ctc, {
  mint: Refine(
    Fun([Address, UInt, UInt, BytesDyn], Null),
    (([to, id, amount, data]) => amount > 0),
    ((args, result) => true)),
  burn: Fun([Address, UInt, UInt], Null),
  balanceOf: Fun([Address, UInt], UInt),
  setApprovalForAll: Fun([Address, Bool], Null),
  isApprovedForAll: Fun([Address, Address], Bool),
  safeTransferFrom: Refine(
    Fun([Address, Address, UInt, UInt, BytesDyn], Null),
    (([from, to, id, amount, data]) => from != to),
    ((args, result) => true)),
  uri: Fun([UInt], StringDyn),
});
