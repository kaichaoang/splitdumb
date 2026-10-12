# SplitLite

A minimal Splitwise-style expense splitter. Static site (HTML/JS) on GitHub Pages, data in Supabase.

Features: groups, members, equal-split expenses, live balances, simplified "who pays whom", settle up, invite by link, password gate.

Multi-currency: every expense and payment has its own currency (3-letter code). Balances and
settle-up are tracked separately per currency, with no exchange-rate conversion, like Splitwise.
Upgrading an existing database: re-run `schema.sql` (it adds the `currency` columns, default SGD).

## Setup

### 1. Supabase
1. Create a project at https://supabase.com.
2. SQL Editor -> paste `schema.sql` -> Run.
3. Project Settings -> API -> copy the **Project URL** and **anon public key**.
4. Put them in `config.js`. (The anon key is meant to be public.)

### 2. GitHub + Pages
```bash
git remote add origin https://github.com/<you>/splitwise-lite.git
git push -u origin main
```
Then on GitHub: repo -> Settings -> Pages -> Source: **Deploy from a branch** -> `main` / `/ (root)`.
Site will be at `https://<you>.github.io/splitwise-lite/`.

## Security note
There is no login. Each group is identified by a random UUID in the link, and the
database policies allow anyone with the anon key to read/write. That's fine for friends
and trips, but anyone who guesses or is given a group link can edit it, and the API
could in principle list all groups. Don't store anything sensitive. If you want real
privacy, add Supabase Auth and tighten the RLS policies to group membership.

## Test
`node test.js` checks the split and balance logic.
