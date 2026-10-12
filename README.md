# SplitDumb

A minimal Splitwise-style expense splitter. Static site (HTML/JS) on GitHub Pages, data in Supabase.

## Features
- **Accounts:** each person signs up with their own username + password and logs in with it.
- **Groups & members:** invite people by link. Opening a link, you pick which member you are (or join as new).
- **Expenses:** default payer is you; you can also add expenses paid by someone else. Every expense records **who added it**.
- **Edit** or delete any expense.
- **Split** equally between chosen people, or **by percentage** (default 50/50, must total 100%).
- **Multi-currency:** each expense has its own currency. Balances, settle-up and spending are tracked per currency, with no conversion.
- **Balances & settle up**, simplified to "who pays whom".
- **Spending per person:** what each person's share of the expenses is, vs what they paid up front.
  (If you pay 30 for a coffee in a 2-person group, your spending is 15 and the other person owes you 15.)

## Setup

### 1. Supabase
1. Create a project at https://supabase.com.
2. SQL Editor -> paste `schema.sql` -> Run. It is safe to re-run; it also upgrades an existing database.
3. Project Settings -> API -> copy the **Project URL** and **publishable (anon) key** into `config.js`. They are meant to be public.

### 2. GitHub Pages
Push to GitHub, then repo -> Settings -> Pages -> Deploy from a branch -> `main` / `/ (root)`.

## Security: please read
- Passwords are stored as bcrypt hashes in a table the API cannot read directly.
- BUT the app only *remembers* who you are in your browser, and the data tables are open to anyone
  holding the public key. So accounts give identity ("added by", your default payer, your group list),
  not hard access control. Anyone technical who knows a group link (or finds the key in `config.js`)
  could read or edit that group's data. Fine for friends and trips; don't store anything sensitive.
- Anyone who can open the site can create an account.
- To make it properly private, move all data access behind server-side functions that check a login
  token (or switch to Supabase Auth with row-level policies).

## Tests
`node test.js` checks the split, percentage, balance and spending logic.
