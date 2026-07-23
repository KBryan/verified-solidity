'reach 0.1';

// Same shape as sol_companion, but the test harness passes
// --companion-check=warn --companion-check-no-solver, exercising the
// solver-unavailable path: the compile succeeds and the analysis is
// recorded as skipped.
export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const A = Participant('A', {});
  init();
  A.publish();
  const ChildCode = ContractCode({ ETH: 'sol_companion_child.sol:Child' });
  const childNew = new Contract(ChildCode, {});
  const child = childNew();
  const c = remote(child, {
    f: Fun([UInt], UInt),
  });
  const r = c.f(1);
  enforce(r <= UInt.max);
  commit();
  exit();
});
