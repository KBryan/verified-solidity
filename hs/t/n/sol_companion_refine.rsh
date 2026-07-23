'reach 0.1';

// The caller violates the companion interface's Refine precondition
// (x < 1000), so Z3 verification fails with a witness, exactly like any
// other assertion failure.
export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const A = Participant('A', {});
  init();
  A.publish();
  const ChildCode = ContractCode({ ETH: 'sol_companion_refine_child.sol:Child' });
  const childNew = new Contract(ChildCode, {});
  const child = childNew();
  const c = remote(child, {
    f: Refine(Fun([UInt], UInt), (([x]) => x < 1000), (([x], r) => r > x)),
  });
  const r = c.f(2000);
  enforce(r > 2000);
  commit();
  exit();
});
