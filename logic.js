// Pure balance logic (no DOM / network) so it can be tested in Node.

const DEFAULT_CURRENCY = "SGD";
const curOf = (x) => x.currency || DEFAULT_CURRENCY;

// Split `amount` equally among `ids`, in cents, remainder spread one cent at a time.
function equalSplit(amount, ids) {
  const cents = Math.round(amount * 100);
  const base = Math.floor(cents / ids.length);
  let rem = cents - base * ids.length;
  return ids.map((id) => {
    const c = base + (rem-- > 0 ? 1 : 0);
    return { member_id: id, share: c / 100 };
  });
}

// Split `amount` by percentages. entries: [{id, percent}], percents may have up to 3 decimals.
// Must add up to exactly 100. Uses integer maths so shares always add up to the amount to the cent.
// Returns [{member_id, share, percent}] (people at 0% are left out).
function percentSplit(amount, entries) {
  const cents = Math.round(amount * 100);
  const items = entries
    .map((e) => ({ id: e.id, p: Math.round((Number(e.percent) || 0) * 1000) }))
    .filter((x) => x.p > 0);
  const total = items.reduce((t, x) => t + x.p, 0);
  if (total !== 100000) throw new Error("Percentages must add up to 100%");
  let used = 0;
  items.forEach((x) => {
    const prod = cents * x.p;
    x.r = prod % 100000;
    x.c = (prod - x.r) / 100000;
    used += x.c;
  });
  let left = cents - used;
  [...items].sort((a, b) => b.r - a.r).forEach((x) => { if (left > 0) { x.c += 1; left -= 1; } });
  return items.map((x) => ({ member_id: x.id, share: x.c / 100, percent: x.p / 1000 }));
}

// Even percentages for a list of ids, in thousandths so they add to exactly 100 (e.g. 3 people: 33.334, 33.333, 33.333).
function equalPercents(ids) {
  const n = ids.length;
  if (!n) return [];
  const base = Math.floor(100000 / n);
  let rem = 100000 - base * n;
  return ids.map((id) => ({ id, percent: (base + (rem-- > 0 ? 1 : 0)) / 1000 }));
}

// Net balance per member in cents. Positive = is owed money, negative = owes.
// If `currency` is given, only expenses/payments in that currency count.
function computeBalances(members, expenses, splits, payments, currency) {
  const want = (x) => currency === undefined || curOf(x) === currency;
  const exp = expenses.filter(want);
  const ids = new Set(exp.map((e) => e.id));
  const spl = splits.filter((s) => ids.has(s.expense_id));
  const pay = payments.filter(want);

  const bal = {};
  members.forEach((m) => (bal[m.id] = 0));
  exp.forEach((e) => (bal[e.paid_by] += Math.round(e.amount * 100)));
  spl.forEach((s) => (bal[s.member_id] -= Math.round(s.share * 100)));
  pay.forEach((p) => {
    bal[p.from_member] += Math.round(p.amount * 100);
    bal[p.to_member] -= Math.round(p.amount * 100);
  });
  return bal;
}

// { SGD: {memberId: cents}, MYR: {...} } — currencies are never mixed or converted.
function balancesByCurrency(members, expenses, splits, payments) {
  const curs = [...new Set([...expenses, ...payments].map(curOf))].sort();
  const out = {};
  curs.forEach((c) => (out[c] = computeBalances(members, expenses, splits, payments, c)));
  return out;
}

// What each person actually spent (their share of every expense) vs what they paid up front.
// Settle-up payments are NOT spending. Cents, per currency:
// { SGD: { total, byMember: { id: { paid, spent } } } }
function spendingByCurrency(members, expenses, splits) {
  const curByExp = {};
  expenses.forEach((e) => (curByExp[e.id] = curOf(e)));
  const tmp = {};
  const ensure = (c) => {
    if (!tmp[c]) {
      tmp[c] = { total: 0, byMember: {} };
      members.forEach((m) => (tmp[c].byMember[m.id] = { paid: 0, spent: 0 }));
    }
    return tmp[c];
  };
  expenses.forEach((e) => {
    const o = ensure(curOf(e));
    const cents = Math.round(e.amount * 100);
    o.total += cents;
    if (o.byMember[e.paid_by]) o.byMember[e.paid_by].paid += cents;
  });
  splits.forEach((s) => {
    const c = curByExp[s.expense_id];
    if (!c) return;
    const row = tmp[c].byMember[s.member_id];
    if (row) row.spent += Math.round(s.share * 100);
  });
  const out = {};
  Object.keys(tmp).sort().forEach((c) => (out[c] = tmp[c]));
  return out;
}

// Greedy debt simplification -> [{from, to, cents}]
function simplifyDebts(bal) {
  const debtors = [], creditors = [];
  Object.entries(bal).forEach(([id, v]) => {
    if (v < 0) debtors.push({ id, v: -v });
    else if (v > 0) creditors.push({ id, v });
  });
  debtors.sort((a, b) => b.v - a.v);
  creditors.sort((a, b) => b.v - a.v);
  const out = [];
  let i = 0, j = 0;
  while (i < debtors.length && j < creditors.length) {
    const pay = Math.min(debtors[i].v, creditors[j].v);
    out.push({ from: debtors[i].id, to: creditors[j].id, cents: pay });
    debtors[i].v -= pay;
    creditors[j].v -= pay;
    if (debtors[i].v === 0) i++;
    if (creditors[j].v === 0) j++;
  }
  return out;
}

if (typeof module !== "undefined") {
  module.exports = {
    equalSplit, percentSplit, equalPercents, computeBalances,
    balancesByCurrency, spendingByCurrency, simplifyDebts,
  };
}
