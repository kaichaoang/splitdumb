// Pure balance logic (no DOM / network) so it can be tested in Node.

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
function computeBalances(members, expenses, splits, payments) {
  const bal = {};
  members.forEach((m) => (bal[m.id] = 0));
  expenses.forEach((e) => (bal[e.paid_by] += Math.round(e.amount * 100)));
  splits.forEach((s) => (bal[s.member_id] -= Math.round(s.share * 100)));
  payments.forEach((p) => {
    bal[p.from_member] += Math.round(p.amount * 100);
    bal[p.to_member] -= Math.round(p.amount * 100);
  });
  return bal;
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

if (typeof module !== "undefined") module.exports = { equalSplit, computeBalances, simplifyDebts };
