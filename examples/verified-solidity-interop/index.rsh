'reach 0.1';

// Reach + hand-written Solidity, verified together.
//
// The Depositor escrows a payment; the payout math lives in a hand-written
// companion contract (Vault.sol) that is deployed and called from this
// program. Three verification layers apply (see the guide chapter
// docs/src/guide/verified-solidity-interop/):
//  1. Z3 verifies this program, and proves the Refine precondition of every
//     vault call at the call site.
//  2. solc's SMTChecker proves the asserts written inside Vault.sol.
//  3. The Refine postcondition (n <= amt) is runtime-enforced and recorded
//     as an explicit boundary assumption in index.main.verify.json.

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });

  const Depositor = Participant('Depositor', {
    amt: UInt,
    ready: Fun([], Null),
  });

  init();

  Depositor.only(() => {
    const amt = declassify(interact.amt);
    assume(amt >= 100 && amt <= 1000000);
  });
  Depositor.publish(amt).pay(amt);
  require(amt >= 100 && amt <= 1000000);
  commit();

  Depositor.only(() => {
    interact.ready();
  });
  Depositor.publish();
  const VaultCode = ContractCode({ ETH: 'Vault.sol:Vault' });
  const vaultNew = new Contract(VaultCode, {});
  const vault = vaultNew();
  const v = remote(vault, {
    net: Refine(
      Fun([UInt], UInt),
      (([a]) => a >= 100 && a <= 1000000),
      (([a], n) => n <= a)),
  });
  const n = v.net(amt);
  transfer(n).to(Depositor);
  transfer(amt - n).to(Depositor);
  commit();

  exit();
});
