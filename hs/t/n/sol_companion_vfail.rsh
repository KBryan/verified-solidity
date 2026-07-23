'reach 0.1';

// The Reach program itself verifies, but the companion contract has a
// violable assert, so the --sol compile must fail and emit no artifacts.
export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const A = Participant('A', {});
  init();
  A.publish();
  const BadCode = ContractCode({ ETH: 'sol_companion_vfail_child.sol:Bad' });
  const badNew = new Contract(BadCode, {});
  const bad = badNew();
  const c = remote(bad, {
    f: Fun([UInt], UInt),
  });
  const r = c.f(1);
  enforce(r <= UInt.max);
  commit();
  exit();
});
