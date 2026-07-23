'reach 0.1';

// Companion Solidity: deploy and call a hand-written contract whose
// SMTChecker properties all prove; the interface's Refine precondition is
// proven at the call site by Z3, and its postcondition is runtime-enforced
// and recorded as a boundary assumption in verify.json.
export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const A = Participant('A', {});
  init();
  A.publish();
  const ChildCode = ContractCode({ ETH: 'sol_companion_child.sol:Child' });
  const childNew = new Contract(ChildCode, {});
  const child = childNew();
  const c = remote(child, {
    f: Refine(Fun([UInt], UInt), (([x]) => x < 1000), (([x], r) => r > x)),
  });
  const r = c.f(1);
  enforce(r > 1);
  commit();
  exit();
});
