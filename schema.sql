-- SplitDumb database. Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run on an existing database (upgrades it in place, keeps your data).
--
-- Security model: the tables are LOCKED (the public API key cannot read or write them).
-- The app talks only to the functions at the bottom. Each one checks the caller's login
-- session, and group data is only returned to people who are members of that group.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- tables
create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  pass_hash text not null,
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

-- login sessions (only a hash of the token is stored)
create table if not exists sessions (
  token_hash text primary key,
  user_id uuid not null references app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 year'
);

-- failed logins, for throttling
create table if not exists login_failures (
  username_lower text not null,
  at timestamptz not null default now()
);

-- ------------------------------------------------- upgrades for existing databases
alter table expenses  add column if not exists currency     text not null default 'SGD';
alter table payments  add column if not exists currency     text not null default 'SGD';
alter table expenses  add column if not exists split_type   text not null default 'equal';
alter table expenses  add column if not exists added_by     uuid references members(id) on delete set null;
alter table expenses  add column if not exists category     text not null default '';   -- '' = no category
alter table splits    add column if not exists percent      numeric(6,3);
alter table members   add column if not exists user_id      uuid references app_users(id) on delete set null;
alter table app_users add column if not exists display_name text;

create unique index if not exists app_users_username_lower on app_users (lower(username));
create unique index if not exists members_group_user_uniq on members(group_id, user_id) where user_id is not null;
create index if not exists members_group_idx  on members(group_id);
create index if not exists members_user_idx   on members(user_id);
create index if not exists expenses_group_idx on expenses(group_id);
create index if not exists splits_expense_idx on splits(expense_id);
create index if not exists payments_group_idx on payments(group_id);
create index if not exists sessions_user_idx  on sessions(user_id);
create index if not exists login_failures_idx on login_failures(username_lower, at);

-- ------------------------------------------------------------- lock the tables
-- No policies and no privileges for the public API roles: only the functions below can touch data.
do $$
declare t text;
begin
  foreach t in array array['groups','members','expenses','splits','payments','app_users','sessions','login_failures'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "open_access" on %I', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- ------------------------------------------------------- remove old versions
drop function if exists save_expense(uuid, uuid, text, numeric, text, uuid, uuid, text, jsonb);
drop function if exists save_expense(text, uuid, uuid, text, numeric, text, uuid, text, jsonb);   -- before categories
drop function if exists register_user(text, text);
drop function if exists login_user(text, text);

alter table sessions alter column expires_at set default now() + interval '1 year';

-- ------------------------------------------------- internal helpers (not callable via the API)
create or replace function user_json(u app_users) returns jsonb
language sql immutable
as $$ select jsonb_build_object('id', u.id, 'username', u.username, 'display_name', coalesce(u.display_name, u.username)) $$;

create or replace function new_session(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  insert into sessions(token_hash, user_id) values (encode(sha256(convert_to(tok, 'utf8')), 'hex'), p_user);
  delete from sessions where expires_at < now();
  return tok;
end $$;

-- who is calling? raises if the token is missing, wrong or expired
create or replace function auth_user(p_token text) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid;
begin
  select s.user_id into uid from sessions s
   where s.token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex') and s.expires_at > now();
  if uid is null then raise exception 'Session expired. Please log in again.'; end if;
  -- stay logged in while you keep using it: push expiry out to a year from the last use
  update sessions set expires_at = now() + interval '1 year'
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex') and expires_at < now() + interval '300 days';
  return uid;
end $$;

-- the caller's member row in a group; raises if they are not in it
create or replace function member_of(p_user uuid, p_group uuid) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare mid uuid;
begin
  select id into mid from members where group_id = p_group and user_id = p_user;
  if mid is null then raise exception 'You are not a member of this group'; end if;
  return mid;
end $$;

-- ------------------------------------------------------------ accounts
create or replace function register_user(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
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
    insert into app_users(username, display_name, pass_hash)
    values (p_username, p_username, crypt(p_password, gen_salt('bf')))
    returning * into u;
  exception when unique_violation then
    raise exception 'That username is already taken';
  end;
  return user_json(u) || jsonb_build_object('token', new_session(u.id));
end $$;

-- Wrong password is RETURNED (not raised) so the failure count survives; raising would roll it back.
create or replace function login_user(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare u app_users; fails int; k text := lower(btrim(coalesce(p_username, '')));
begin
  delete from login_failures where at < now() - interval '1 hour';
  select count(*) into fails from login_failures where username_lower = k and at > now() - interval '15 minutes';
  if fails >= 8 then
    raise exception 'Too many failed attempts. Please wait 15 minutes and try again.';
  end if;
  select * into u from app_users where lower(username) = k;
  if not found or u.pass_hash <> crypt(coalesce(p_password, ''), u.pass_hash) then
    insert into login_failures(username_lower) values (k);
    return jsonb_build_object('error', 'Wrong username or password');
  end if;
  delete from login_failures where username_lower = k;
  return user_json(u) || jsonb_build_object('token', new_session(u.id));
end $$;

create or replace function logout(p_token text) returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  delete from sessions where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  return true;
end $$;

create or replace function me(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare u app_users;
begin
  select * into u from app_users where id = auth_user(p_token);
  return user_json(u);
end $$;

create or replace function change_password(p_token text, p_old text, p_new text) returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); u app_users;
begin
  select * into u from app_users where id = uid;
  if u.pass_hash <> crypt(coalesce(p_old, ''), u.pass_hash) then raise exception 'Current password is wrong'; end if;
  if p_new is null or length(p_new) < 6 then raise exception 'New password must be at least 6 characters'; end if;
  update app_users set pass_hash = crypt(p_new, gen_salt('bf')) where id = uid;
  -- sign out everywhere else
  delete from sessions where user_id = uid and token_hash <> encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  return true;
end $$;

-- Change your display name. It is shown in every group you are in.
create or replace function set_display_name(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); n text := btrim(coalesce(p_name, '')); u app_users;
begin
  if n = '' or length(n) > 30 or n ~ '[[:cntrl:]]' then raise exception 'Display name must be 1-30 characters'; end if;
  update app_users set display_name = n where id = uid returning * into u;
  update members set name = n where user_id = uid;
  return user_json(u);
end $$;

-- ------------------------------------------------------------ groups
-- A trip is settled when, in every currency, everyone's paid / share / settle-up payments net to zero.
create or replace function group_settled(p_group uuid) returns boolean
language sql stable
as $$
  select not exists (
    select 1 from (
      select currency, member_id, sum(v) as bal from (
        select e.currency, e.paid_by as member_id, e.amount as v from expenses e where e.group_id = p_group
        union all
        select e.currency, s.member_id, -s.share from splits s join expenses e on e.id = s.expense_id where e.group_id = p_group
        union all
        select p.currency, p.from_member, p.amount from payments p where p.group_id = p_group
        union all
        select p.currency, p.to_member, -p.amount from payments p where p.group_id = p_group
      ) x group by currency, member_id
    ) y where bal <> 0);
$$;

-- The trips you are in, for the side menu. expense_count = 0 means nothing recorded yet.
create or replace function my_groups(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
                     'id', g.id, 'name', g.name,
                     'expense_count', (select count(*) from expenses e where e.group_id = g.id),
                     'settled', group_settled(g.id)) order by g.name)
                     from groups g join members m on m.group_id = g.id where m.user_id = uid), '[]'::jsonb);
end $$;

-- p_others: names of people without an account (you can add accounts by username inside the group)
create or replace function create_group(p_token text, p_name text, p_others text[]) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); u app_users; gid uuid; n text; nm text; seen text[];
begin
  if btrim(coalesce(p_name, '')) = '' or length(btrim(p_name)) > 60 then
    raise exception 'Group name must be 1-60 characters';
  end if;
  select * into u from app_users where id = uid;
  insert into groups(name) values (btrim(p_name)) returning id into gid;
  insert into members(group_id, name, user_id) values (gid, coalesce(u.display_name, u.username), uid);
  seen := array[lower(coalesce(u.display_name, u.username))];
  foreach n in array coalesce(p_others, array[]::text[]) loop
    nm := btrim(n);
    if nm <> '' and length(nm) <= 30 and not (lower(nm) = any(seen)) then
      insert into members(group_id, name) values (gid, nm);
      seen := seen || lower(nm);
    end if;
  end loop;
  return jsonb_build_object('id', gid);
end $$;

-- Everything the group page needs, in one call. Only for members of the group.
create or replace function get_group(p_token text, p_group uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); mid uuid := member_of(uid, p_group);
begin
  return jsonb_build_object(
    'group',   (select jsonb_build_object('id', g.id, 'name', g.name) from groups g where g.id = p_group),
    'me',      mid,
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'username', u.username,
                                                              'linked', m.user_id is not null) order by m.name)
                           from members m left join app_users u on u.id = m.user_id where m.group_id = p_group), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from expenses e where e.group_id = p_group), '[]'::jsonb),
    'splits',   coalesce((select jsonb_agg(to_jsonb(s)) from splits s join expenses e on e.id = s.expense_id where e.group_id = p_group), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from payments p where p.group_id = p_group), '[]'::jsonb)
  );
end $$;

-- Add a person to a group you are in. With p_username: links that existing account.
-- Without: adds a name-only person (no account).
create or replace function add_member(p_token text, p_group uuid, p_name text, p_username text) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); mid uuid := member_of(uid, p_group); u app_users; nid uuid; n text := btrim(coalesce(p_name, ''));
begin
  if btrim(coalesce(p_username, '')) <> '' then
    select * into u from app_users where lower(username) = lower(btrim(p_username));
    if not found then raise exception 'No account with that username'; end if;
    if exists (select 1 from members where group_id = p_group and user_id = u.id) then
      raise exception 'They are already in this group';
    end if;
    insert into members(group_id, name, user_id) values (p_group, coalesce(u.display_name, u.username), u.id) returning id into nid;
  else
    if n = '' or length(n) > 30 then raise exception 'Name must be 1-30 characters'; end if;
    insert into members(group_id, name) values (p_group, n) returning id into nid;
  end if;
  return nid;
end $$;

-- Attach an existing account to a name-only member (e.g. someone you added before they signed up).
create or replace function link_member(p_token text, p_member uuid, p_username text) returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); gid uuid; existing uuid; u app_users;
begin
  select group_id, user_id into gid, existing from members where id = p_member;
  if gid is null then raise exception 'Member not found'; end if;
  perform member_of(uid, gid);
  if existing is not null then raise exception 'That person already has an account linked'; end if;
  select * into u from app_users where lower(username) = lower(btrim(coalesce(p_username, '')));
  if not found then raise exception 'No account with that username'; end if;
  if exists (select 1 from members where group_id = gid and user_id = u.id) then
    raise exception 'That account is already in this group';
  end if;
  update members set user_id = u.id, name = coalesce(u.display_name, u.username) where id = p_member;
  return true;
end $$;

-- ------------------------------------------------------------ expenses
-- Create (p_id null) or update an expense and its splits in ONE transaction.
-- "Added by" is always the caller, set by the server.
-- p_splits: [{"member_id": "...", "share": 15.00, "percent": 50}]  (percent only for split_type 'percent')
-- p_category: '' (none) or one of transport, food, utilities, accommodation, gift. Optional, so older callers still work.
create or replace function save_expense(
  p_token text, p_id uuid, p_group uuid, p_description text, p_amount numeric, p_currency text,
  p_paid_by uuid, p_split_type text, p_splits jsonb, p_category text default ''
) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  uid uuid := auth_user(p_token);
  mid uuid := member_of(uid, p_group);
  v_id uuid := p_id;
  v_desc text := btrim(coalesce(p_description, ''));
  v_cat text := btrim(coalesce(p_category, ''));
  v_total numeric;
begin
  if v_desc = '' or length(v_desc) > 120 then raise exception 'Description must be 1-120 characters'; end if;
  if v_cat not in ('', 'transport', 'food', 'utilities', 'accommodation', 'gift') then raise exception 'Unknown category'; end if;
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
    insert into expenses(group_id, description, amount, currency, paid_by, added_by, split_type, category)
    values (p_group, v_desc, p_amount, p_currency, p_paid_by, mid, p_split_type, v_cat)
    returning id into v_id;
  else
    update expenses
       set description = v_desc, amount = p_amount, currency = p_currency,
           paid_by = p_paid_by, split_type = p_split_type, category = v_cat
     where id = v_id and group_id = p_group;
    if not found then raise exception 'Expense not found'; end if;
    delete from splits where expense_id = v_id;
  end if;

  insert into splits(expense_id, member_id, share, percent)
  select v_id, (s->>'member_id')::uuid, (s->>'share')::numeric, nullif(s->>'percent', '')::numeric
    from jsonb_array_elements(p_splits) s;

  return v_id;
end $$;

create or replace function delete_expense(p_token text, p_expense uuid) returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); gid uuid;
begin
  select group_id into gid from expenses where id = p_expense;
  if gid is null then raise exception 'Expense not found'; end if;
  perform member_of(uid, gid);
  delete from expenses where id = p_expense;
  return true;
end $$;

create or replace function add_payment(
  p_token text, p_group uuid, p_from uuid, p_to uuid, p_amount numeric, p_currency text
) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); pid uuid;
begin
  perform member_of(uid, p_group);
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be more than 0'; end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then raise exception 'Currency must be a 3-letter code'; end if;
  if p_from = p_to then raise exception 'Payer and receiver must be different people'; end if;
  if (select count(*) from members where group_id = p_group and id in (p_from, p_to)) <> 2 then
    raise exception 'Both people must be in this group';
  end if;
  insert into payments(group_id, from_member, to_member, amount, currency)
  values (p_group, p_from, p_to, p_amount, p_currency) returning id into pid;
  return pid;
end $$;

-- Rename a trip you are in.
create or replace function rename_group(p_token text, p_group uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare uid uuid := auth_user(p_token); mid uuid := member_of(uid, p_group);
begin
  if btrim(coalesce(p_name, '')) = '' or length(btrim(p_name)) > 60 then
    raise exception 'Trip name must be 1-60 characters';
  end if;
  update groups set name = btrim(p_name) where id = p_group;
  return jsonb_build_object('id', p_group, 'name', btrim(p_name));
end $$;

-- ------------------------------------------------------------ who may call what
revoke all on function user_json(app_users), new_session(uuid), auth_user(text), member_of(uuid, uuid), group_settled(uuid)
  from public, anon, authenticated;

grant execute on function
  register_user(text, text), login_user(text, text), logout(text), me(text),
  change_password(text, text, text), set_display_name(text, text),
  my_groups(text), create_group(text, text, text[]), rename_group(text, uuid, text), get_group(text, uuid),
  add_member(text, uuid, text, text), link_member(text, uuid, text),
  save_expense(text, uuid, uuid, text, numeric, text, uuid, text, jsonb, text),
  delete_expense(text, uuid), add_payment(text, uuid, uuid, uuid, numeric, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
