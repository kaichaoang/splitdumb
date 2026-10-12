const assert = require("assert");
const L = require("./logic.js");
const { equalSplit, percentSplit, equalPercents, computeBalances, balancesByCurrency, spendingByCurrency, simplifyDebts } = L;

const sum = (o) => Object.values(o).reduce((t, v) => t + v, 0);
const cents = (rows) => Math.round(rows.reduce((t, x) => t + x.share, 0) * 100);

// ---- equal split ----
assert.strictEqual(cents(equalSplit(10, ["a", "b", "c"])), 1000);

// ---- basic balances ----
const members = [{ id: "a" }, { id: "b" }, { id: "c" }];
const expenses = [{ id: "e1", amount: 90, paid_by: "a" }, { id: "e2", amount: 30, paid_by: "b" }];
const splits = [
  ...equalSplit(90, ["a", "b", "c"]).map((x) => ({ ...x, expense_id: "e1" })),
  ...equalSplit(30, ["b", "c"]).map((x) => ({ ...x, expense_id: "e2" })),
];
let bal = computeBalances(members, expenses, splits, []);
assert.deepStrictEqual(bal, { a: 6000, b: -1500, c: -4500 });
assert.strictEqual(sum(bal), 0);

const debts = simplifyDebts(bal);
const payments = debts.map((d) => ({ from_member: d.from, to_member: d.to, amount: d.cents / 100 }));
bal = computeBalances(members, expenses, splits, payments);
assert.ok(Object.values(bal).every((v) => v === 0));

// ---- multi-currency never mixes ----
const m2 = [{ id: "y" }, { id: "k" }];
const ex2 = [
  { id: "x1", amount: 70, paid_by: "y", currency: "SGD" },
  { id: "x2", amount: 40.7, paid_by: "k", currency: "MYR" },
  { id: "x3", amount: 21, paid_by: "y", currency: "MYR" },
];
const sp2 = ex2.flatMap((e) => equalSplit(e.amount, ["y", "k"]).map((x) => ({ ...x, expense_id: e.id })));
const by = balancesByCurrency(m2, ex2, sp2, []);
assert.deepStrictEqual(Object.keys(by), ["MYR", "SGD"]);
assert.deepStrictEqual(by.SGD, { y: 3500, k: -3500 });
assert.deepStrictEqual(by.MYR, { y: 1050 - 2035, k: 2035 - 1050 });
const by2 = balancesByCurrency(m2, ex2, sp2, [{ from_member: "k", to_member: "y", amount: 35, currency: "SGD" }]);
assert.deepStrictEqual(by2.SGD, { y: 0, k: 0 });
assert.deepStrictEqual(by2.MYR, by.MYR);

// ---- percentage split ----
// 70/30 of 10.01 -> exact cents
let p = percentSplit(10.01, [{ id: "a", percent: 70 }, { id: "b", percent: 30 }]);
assert.strictEqual(cents(p), 1001);
assert.deepStrictEqual(p.map((x) => x.share), [7.01, 3.0]); // 7.007 -> .007 rounds in favour of largest remainder
// default 50/50
p = percentSplit(30, [{ id: "a", percent: 50 }, { id: "b", percent: 50 }]);
assert.deepStrictEqual(p.map((x) => x.share), [15, 15]);
// thirds always add up exactly, for awkward amounts too
for (const amt of [0.01, 0.02, 1, 10, 33.33, 100.01, 999.99, 1234.56]) {
  const e = equalPercents(["a", "b", "c"]);
  assert.strictEqual(Math.round(e.reduce((t, x) => t + x.percent, 0) * 1000), 100000);
  assert.strictEqual(cents(percentSplit(amt, e)), Math.round(amt * 100), "amount " + amt);
}
assert.deepStrictEqual(equalPercents(["a", "b"]).map((x) => x.percent), [50, 50]);
// zero-percent people are left out; bad totals throw
assert.deepStrictEqual(percentSplit(10, [{ id: "a", percent: 100 }, { id: "b", percent: 0 }]).map((x) => x.member_id), ["a"]);
assert.throws(() => percentSplit(10, [{ id: "a", percent: 60 }, { id: "b", percent: 30 }]), /100%/);
assert.throws(() => percentSplit(10, [{ id: "a", percent: 60 }, { id: "b", percent: 41 }]), /100%/);
// fractional percents (33.333 x3 + 0.001)
assert.strictEqual(cents(percentSplit(50, [{ id: "a", percent: 33.334 }, { id: "b", percent: 33.333 }, { id: "c", percent: 33.333 }])), 5000);

// ---- the coffee example: I pay $30 for a coffee for a 2-person group ----
const me = { id: "me" }, you = { id: "you" };
const coffee = [{ id: "c1", amount: 30, paid_by: "me", currency: "SGD" }];
const coffeeSplits = equalSplit(30, ["me", "you"]).map((x) => ({ ...x, expense_id: "c1" }));
const sp = spendingByCurrency([me, you], coffee, coffeeSplits);
assert.deepStrictEqual(sp.SGD.byMember.me, { paid: 3000, spent: 1500 }); // I paid 30 but MY expense is 15
assert.deepStrictEqual(sp.SGD.byMember.you, { paid: 0, spent: 1500 });
assert.strictEqual(sp.SGD.total, 3000);
assert.deepStrictEqual(computeBalances([me, you], coffee, coffeeSplits, []), { me: 1500, you: -1500 }); // you owe me 15

// Spending ignores settle-ups, is per currency, and totals match
const sp3 = spendingByCurrency(m2, ex2, sp2);
assert.deepStrictEqual(Object.keys(sp3), ["MYR", "SGD"]);
for (const c of Object.keys(sp3)) {
  const s = Object.values(sp3[c].byMember);
  assert.strictEqual(s.reduce((t, x) => t + x.spent, 0), sp3[c].total);
  assert.strictEqual(s.reduce((t, x) => t + x.paid, 0), sp3[c].total);
}
// percent-split spending: 70/30 of 100 paid by A
const pe = [{ id: "p1", amount: 100, paid_by: "a", currency: "SGD" }];
const ps = percentSplit(100, [{ id: "a", percent: 70 }, { id: "b", percent: 30 }]).map((x) => ({ ...x, expense_id: "p1" }));
const sp4 = spendingByCurrency([{ id: "a" }, { id: "b" }], pe, ps);
assert.deepStrictEqual(sp4.SGD.byMember, { a: { paid: 10000, spent: 7000 }, b: { paid: 0, spent: 3000 } });

// ---- spending by category: per currency, uncategorised kept apart, totals match ----
const ce = [
  { id: "k1", amount: 12.5, currency: "SGD", category: "food" },
  { id: "k2", amount: 7.5, currency: "SGD", category: "food" },
  { id: "k3", amount: 30, currency: "SGD", category: "transport" },
  { id: "k4", amount: 5, currency: "SGD" },                       // no category (legacy row)
  { id: "k5", amount: 100, currency: "MYR", category: "gift" },
  { id: "k6", amount: 9.99, currency: "MYR", category: "mystery" }, // unknown id
];
const cs = L.spendingByCategory(ce);
assert.deepStrictEqual(Object.keys(cs), ["MYR", "SGD"]);
assert.deepStrictEqual(cs.SGD.byCat, { food: 2000, transport: 3000, "": 500 });
assert.strictEqual(cs.SGD.total, 5500);
assert.deepStrictEqual(cs.MYR.byCat, { gift: 10000, mystery: 999 });
for (const c of Object.keys(cs)) assert.strictEqual(Object.values(cs[c].byCat).reduce((t, v) => t + v, 0), cs[c].total);
// folding unknown ids into "no category"
const ok = new Set(["food", "transport", "gift"]);
assert.deepStrictEqual(L.spendingByCategory(ce, (c) => (ok.has(c) ? c : "")).MYR.byCat, { gift: 10000, "": 999 });
// and it agrees with the per-person spending totals
const spAll = spendingByCurrency(m2, ex2, sp2);
const csAll = L.spendingByCategory(ex2);
for (const c of Object.keys(spAll)) assert.strictEqual(csAll[c].total, spAll[c].total);

// legacy rows without a currency count as the default currency
assert.deepStrictEqual(Object.keys(balancesByCurrency(m2, [{ id: "z", amount: 10, paid_by: "y" }], equalSplit(10, ["y", "k"]).map((x) => ({ ...x, expense_id: "z" })), [])), ["SGD"]);

console.log("all good");
