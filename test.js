const assert = require("assert");
const { equalSplit, computeBalances, balancesByCurrency, simplifyDebts } = require("./logic.js");

const sum = (o) => Object.values(o).reduce((t, v) => t + v, 0);

// 10.00 split 3 ways -> cents add up exactly
const s = equalSplit(10, ["a", "b", "c"]);
assert.strictEqual(Math.round(s.reduce((t, x) => t + x.share, 0) * 100), 1000);

// A pays 90 for A,B,C; B pays 30 for B,C
const members = [{ id: "a" }, { id: "b" }, { id: "c" }];
const expenses = [{ id: "e1", amount: 90, paid_by: "a" }, { id: "e2", amount: 30, paid_by: "b" }];
const splits = [
  ...equalSplit(90, ["a", "b", "c"]).map((x) => ({ ...x, expense_id: "e1" })),
  ...equalSplit(30, ["b", "c"]).map((x) => ({ ...x, expense_id: "e2" })),
];
let bal = computeBalances(members, expenses, splits, []);
assert.deepStrictEqual(bal, { a: 6000, b: -1500, c: -4500 });
assert.strictEqual(sum(bal), 0);

// Settling the simplified debts zeroes everyone out
const debts = simplifyDebts(bal);
const payments = debts.map((d) => ({ from_member: d.from, to_member: d.to, amount: d.cents / 100 }));
bal = computeBalances(members, expenses, splits, payments);
assert.ok(Object.values(bal).every((v) => v === 0));

// ---- Multi-currency: balances must never mix currencies ----
const m2 = [{ id: "y" }, { id: "k" }];
const ex2 = [
  { id: "x1", amount: 70, paid_by: "y", currency: "SGD" },   // Y paid, 50/50
  { id: "x2", amount: 40.7, paid_by: "k", currency: "MYR" }, // K paid, 50/50
  { id: "x3", amount: 21, paid_by: "y", currency: "MYR" },
];
const sp2 = ex2.flatMap((e) => equalSplit(e.amount, ["y", "k"]).map((x) => ({ ...x, expense_id: e.id })));
const by = balancesByCurrency(m2, ex2, sp2, []);
assert.deepStrictEqual(Object.keys(by), ["MYR", "SGD"]);
assert.deepStrictEqual(by.SGD, { y: 3500, k: -3500 });
assert.deepStrictEqual(by.MYR, { y: 1050 - 2035, k: 2035 - 1050 }); // Y: +10.50 -20.35 = -9.85
assert.ok(Object.values(by).every((b) => sum(b) === 0));

// Paying off SGD debt must not touch MYR
const paySgd = [{ from_member: "k", to_member: "y", amount: 35, currency: "SGD" }];
const by2 = balancesByCurrency(m2, ex2, sp2, paySgd);
assert.deepStrictEqual(by2.SGD, { y: 0, k: 0 });
assert.deepStrictEqual(by2.MYR, by.MYR);

// Rows with no currency (legacy) count as the default currency
assert.deepStrictEqual(Object.keys(balancesByCurrency(m2, [{ id: "z", amount: 10, paid_by: "y" }], equalSplit(10, ["y", "k"]).map((x) => ({ ...x, expense_id: "z" })), [])), ["SGD"]);

console.log("all good");
