-- Run this in Supabase: SQL Editor -> New query -> paste -> Run

create extension if not exists "pgcrypto";

create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  name text not null
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  paid_by uuid not null references members(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists splits (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references expenses(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  share numeric(12,2) not null
);

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  from_member uuid not null references members(id) on delete cascade,
  to_member uuid not null references members(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);

create index if not exists members_group_idx on members(group_id);
create index if not exists expenses_group_idx on expenses(group_id);
create index if not exists splits_expense_idx on splits(expense_id);
create index if not exists payments_group_idx on payments(group_id);

-- Row Level Security: open access for anyone holding the anon key.
-- Groups are "private by link" (random UUID), NOT truly secure. See README.
alter table groups   enable row level security;
alter table members  enable row level security;
alter table expenses enable row level security;
alter table splits   enable row level security;
alter table payments enable row level security;

do $$
declare t text;
begin
  foreach t in array array['groups','members','expenses','splits','payments'] loop
    execute format('drop policy if exists "open_access" on %I', t);
    execute format('create policy "open_access" on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;
