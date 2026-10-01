'reach 0.1';

// Under --sol arithmetic is always verified: this program opts out with
// setOptions({ verifyArithmetic: false }), yet the unbounded addition must
// still fail verification with an overflow counterexample.
export const main = Reach.App(() => {
  setOptions({ verifyArithmetic: false });
  const A = Participant('Alice', {
    x: UInt,
    y: UInt,
    show: Fun([UInt], Null),
  });

  init();

  A.only(() => {
    const x = declassify(interact.x);
    const y = declassify(interact.y);
  });
  A.publish(x, y);
  const z = x + y;
  commit();

  A.only(() => {
    interact.show(z);
  });

  exit();
});
