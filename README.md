# SplitDumb

A minimal Splitwise-style expense splitter. Static site (HTML/JS) on GitHub Pages, data in Supabase.

## Features
- **Accounts:** sign up with a username + password. Change your **display name** and password under *Account*.
- **Trips (groups):** you only see trips you are a member of. A side menu lists them, each tagged **New**, **Unsettled** or **Settled**. Every page has an "← All trips" link.
- **Adding people:** an existing member adds you by your **username** (or links a name-only person to your account). Having a trip's link is **not** enough to get in.
- **Expenses:** default payer is you; you can add expenses paid by someone else. Each records **who added it**. Edit or delete any expense (pencil and bin icons). The pencil opens the editor right inside that expense in the list.
- **Categories:** tag an expense as Transport, Food, Utilities, Accommodation or Gift, or leave it as None. The icon shows next to the expense, and the CSV export has a Category column.
- **Split** equally between chosen people, or **by percentage** (default 50/50, must total 100%).
- **Multi-currency:** each expense has its own currency. Balances, settle-up and spending are per currency, no conversion.
- **Statistics:** per currency, each person's portion of the trip's spending and a breakdown by category, as percentages, shown as a donut chart plus labelled bars.
- **Spending per person:** your share of the expenses vs what you paid up front (pay 30 for a coffee in a 2-person group: your spending is 15, the other person owes you 15).

## Setup

### 1. Supabase
1. Create a project at https://supabase.com.
2. SQL Editor -> paste `schema.sql` -> Run. Safe to re-run; it upgrades an existing database and keeps the data.
3. Project Settings -> API -> copy the **Project URL** and **publishable (anon) key** into `config.js`. They are meant to be public.

### 2. GitHub Pages
Push to GitHub, then repo -> Settings -> Pages -> Deploy from a branch -> `main` / `/ (root)`.

## Security model
- The data tables are locked: no direct access with the public key at all.
- Every action goes through a server-side function that checks a login token and that you are a member of the trip.
  Someone who finds a trip link, or calls the API by hand, gets "You are not a member of this group".
- Passwords are bcrypt hashes. Login tokens are random, only their hash is stored, and they expire after 60 days.
  Changing your password signs you out elsewhere. Repeated wrong passwords are throttled.
- Anyone can create an account, but a new account sees nothing until someone adds it to a trip.
- Not for sensitive data: this is a hobby app, not a bank.

## Tests
`node test.js` checks the split, percentage, balance and spending logic.
