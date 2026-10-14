# SplitDumb

A minimal Splitwise-style expense splitter. Static site (HTML/JS) on GitHub Pages, data in Supabase.

## Features
- **Accounts:** sign up with a username + password. Under *Account* you can change your **display name**, password and **profile picture** (cropped to a small square and shown next to your name in every trip).
- **Trips (groups):** you only see trips you are a member of. A side menu lists them, each tagged **New**, **Unsettled** or **Settled**. Every page has an "← All trips" link.
- **Adding people:** an existing member adds you by your **username** (or links a name-only person to your account). Having a trip's link is **not** enough to get in. Tap anyone in the People list for a quick profile card (picture, username, what they spent and their balance in this trip).
- **Expenses:** default payer is you; you can add expenses paid by someone else. Each records **who added it**. Edit or delete any expense (pencil and bin icons). The pencil opens the editor right inside that expense in the list.
- **Date and time:** every expense has a When field (defaults to now, editable). Lists, date filters and CSV export use it; older expenses were set to 12:00 noon on the day they were added.
- **Categories:** tag an expense as Transport, Food, Utilities, Accommodation, Gift, Entertainment, Apparel or Misc, or leave it as None. The icon shows next to the expense, and the CSV export has a Category column.
- **Split** equally between chosen people, or **by percentage** (default 50/50, must total 100%).
- **Multi-currency:** each expense has its own currency. Balances, settle-up and spending are per currency, no conversion.
- **Statistics:** one chart at a time, switch between **By person** and **By category**, for **all currencies combined** (converted into one currency you pick, default SGD) or any single currency.
- **Exchange rates** (combined view only): live rates from a free public API (open.er-api.com), cached for 12 hours, with rough built-in estimates as a fallback. It is an estimate; balances and settle-up never mix currencies.
- **Spending per person:** in Statistics, each person's share of the expenses. Tap a person to see what they spent it on, by category.

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
