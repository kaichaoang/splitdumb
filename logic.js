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
  module.exports = { equalSplit, computeBalances, balancesByCurrency, simplifyDebts };
}
