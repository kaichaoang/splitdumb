-- SplitDumb database. Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run on an existing database (upgrades it in place).

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- tables
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

-- Accounts. Passwords are bcrypt-hashed; this table is NOT readable through the API,
-- only the register_user / login_user functions below can touch it.
create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  pass_hash text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists app_users_username_lower on app_users (lower(username));

-- ------------------------------------------------- upgrades for existing databases
alter table expenses add column if not exists currency   text not null default 'SGD';
alter table payments add column if not exists currency   text not null default 'SGD';
alter table expenses add column if not exists split_type text not null default 'equal';
alter table expenses add column if not exists added_by   uuid references members(id) on delete set null;
alter table splits   add column if not exists percent    numeric(6,3);
alter table members  add column if not exists user_id    uuid references app_users(id) on delete set null;

create unique index if not exists members_group_user_uniq on members(group_id, user_id) where user_id is not null;
create index if not exists members_group_idx  on members(group_id);
create index if not exists members_user_idx   on members(user_id);
create index if not exists expenses_group_idx on expenses(group_id);
create index if not exists splits_expense_idx on splits(expense_id);
create index if not exists payments_group_idx on payments(group_id);

-- ------------------------------------------------------------- security
-- Data tables: open to anyone holding the anon key (groups are "private by link").
-- This is NOT strong security. See README.
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

-- Accounts: no policies at all, so the API cannot read or write app_users directly.
alter table app_users enable row level security;
revoke all on app_users from anon, authenticated;

-- ------------------------------------------------------------ functions
create or replace function register_user(p_username text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare u app_users;
begin
  if p_username is null or p_username !~ '^[A-Za-z0-9_.-]{2,20}$' then
    raise exception 'Username must be 2-20 characters: letters, numbers, . _ -';
  end if;
  if p_password is null or length(p_password) < 6 then
    raise exception 'Password must be at least 6 characters';
  end if;
  begin
    insert into app_users(username, pass_hash)
    values (p_username, crypt(p_password, gen_salt('bf')))
    returning * into u;
  exception when unique_violation then
    raise exception 'That username is already taken';
  end;
  return json_build_object('id', u.id, 'username', u.username);
end $$;

create or replace function login_user(p_username text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare u app_users;
begin
  select * into u from app_users where lower(username) = lower(coalesce(p_username, ''));
  if not found or u.pass_hash <> crypt(coalesce(p_password, ''), u.pass_hash) then
    raise exception 'Wrong username or password';
  end if;
  return json_build_object('id', u.id, 'username', u.username);
end $$;

grant execute on function register_user(text, text) to anon, authenticated;
grant execute on function login_user(text, text)    to anon, authenticated;

-- Create (p_id null) or update an expense and its splits in ONE transaction,
-- checking that the shares add up to the amount.
-- p_splits: [{"member_id": "...", "share": 15.00, "percent": 50}]  (percent only for split_type 'percent')
create or replace function save_expense(
  p_id uuid, p_group uuid, p_description text, p_amount numeric, p_currency text,
  p_paid_by uuid, p_added_by uuid, p_split_type text, p_splits jsonb
) returns uuid
language plpgsql
as $$
declare
  v_id uuid := p_id;
  v_total numeric;
begin
  if p_split_type not in ('equal', 'percent') then raise exception 'Bad split type'; end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then raise exception 'Currency must be a 3-letter code'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be more than 0'; end if;
  if p_splits is null or jsonb_typeof(p_splits) <> 'array' or jsonb_array_length(p_splits) = 0 then
    raise exception 'Pick at least one person to split with';
  end if;

  select coalesce(sum((s->>'share')::numeric), 0) into v_total from jsonb_array_elements(p_splits) s;
  if round(v_total, 2) <> round(p_amount, 2) then
    raise exception 'Shares (%) do not add up to the amount (%)', v_total, p_amount;
  end if;
  if not exists (select 1 from members where id = p_paid_by and group_id = p_group) then
    raise exception 'Payer is not in this group';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_splits) s
    where not exists (select 1 from members m where m.id = (s->>'member_id')::uuid and m.group_id = p_group)
  ) then
    raise exception 'The split includes someone outside this group';
  end if;

  if v_id is null then
    insert into expenses(group_id, description, amount, currency, paid_by, added_by, split_type)
    values (p_group, p_description, p_amount, p_currency, p_paid_by, p_added_by, p_split_type)
    returning id into v_id;
  else
    update expenses
       set description = p_description, amount = p_amount, currency = p_currency,
           paid_by = p_paid_by, split_type = p_split_type
     where id = v_id and group_id = p_group;
    if not found then raise exception 'Expense not found'; end if;
    delete from splits where expense_id = v_id;
  end if;

  insert into splits(expense_id, member_id, share, percent)
  select v_id, (s->>'member_id')::uuid, (s->>'share')::numeric, nullif(s->>'percent', '')::numeric
    from jsonb_array_elements(p_splits) s;

  return v_id;
end $$;

grant execute on function save_expense(uuid, uuid, text, numeric, text, uuid, uuid, text, jsonb) to anon, authenticated;
