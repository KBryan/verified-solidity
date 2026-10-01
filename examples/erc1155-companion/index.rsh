'reach 0.1';

import { deployERC1155, ERC1155Interface } from './erc1155.rsh';

// Reach + a vendored OpenZeppelin ERC1155 companion, verified together.
//
// Admin deploys an ERC1155Wrapped token (ERC1155Wrapped.sol) and names a
// recipient; that recipient (bound as the Recipient participant, so nobody
// else can claim the mint) triggers the mint of `amount` units of a single
// token `tokenId` to itself and is shown the resulting balance. Three verification layers apply (see
// docs/src/guide/verified-solidity-interop/):
//  1. Z3 verifies this program's orchestration and proves the Refine
//     preconditions of every companion call (erc1155.rsh) at the call site.
//  2. solc's SMTChecker proves internal arithmetic/assert safety across
//     ERC1155Wrapped.sol and its full OpenZeppelin dependency closure.
//     It does NOT prove ERC1155 semantic properties such as balance/supply
//     conservation across mint/transfer -- OZ's base ERC1155 doesn't track
//     total supply (that's the separate ERC1155Supply extension, not
//     vendored here), and no cross-call property is asserted in Solidity.
//  3. Every companion call result is otherwise `havoc` (unconstrained) to
//     Z3; recorded explicitly in vr_assumptions. In particular, the
//     `balanceOf` value reported to Recipient below is neither proven nor
//     checked: it is whatever the companion returns, passed through to the
//     frontend for display.

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });

  const Admin = Participant('Admin', {
    uri: StringDyn,
    tokenId: UInt,
    amount: UInt,
    recipient: Address,
    ready: Fun([], Null),
  });
  const Recipient = Participant('Recipient', {
    ready: Fun([], Null),
    reportBalance: Fun([UInt], Null),
  });

  init();

  Admin.only(() => {
    const uri = declassify(interact.uri);
    const tokenId = declassify(interact.tokenId);
    const amount = declassify(interact.amount);
    const recipient = declassify(interact.recipient);
    assume(amount > 0);
  });
  Admin.publish(uri, tokenId, amount, recipient);
  require(amount > 0);
  // Without this, whoever published the Recipient step first would become
  // Recipient and receive the mint.
  Recipient.set(recipient);
  commit();

  Admin.only(() => {
    interact.ready();
  });
  Admin.publish();
  const token = deployERC1155(uri);
  const t = ERC1155Interface(token);
  commit();

  Recipient.only(() => {
    interact.ready();
  });
  Recipient.publish();
  t.mint(Recipient, tokenId, amount, BytesDyn(''));
  const bal = t.balanceOf(Recipient, tokenId);
  commit();

  Recipient.only(() => {
    interact.reportBalance(bal);
  });

  exit();
});
