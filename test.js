const assert = require("assert");
const { equalSplit, computeBalances, simplifyDebts } = require("./logic.js");

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
assert.deepStrictEqual(bal, { a: 6000, b: -1500 + 0 - 0 + 0 === -1500 ? -1500 : 0, c: -4500 });
assert.strictEqual(Object.values(bal).reduce((t, v) => t + v, 0), 0);

// Settling the simplified debts zeroes everyone out
const debts = simplifyDebts(bal);
const payments = debts.map((d) => ({ from_member: d.from, to_member: d.to, amount: d.cents / 100 }));
bal = computeBalances(members, expenses, splits, payments);
assert.ok(Object.values(bal).every((v) => v === 0));
console.log("all good");
