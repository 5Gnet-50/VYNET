-- Core schema. Apply only to a new project or through a reviewed migration workflow.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 160),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 160),
  phone text not null unique check (phone ~ '^7[0-9]{8}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  role text not null check (role in ('OWNER', 'ADMIN', 'AGENT', 'CUSTOMER')),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id),
  unique (organization_id, id)
);

create table public.agents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id),
  unique (organization_id, id)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(user_id) on delete cascade,
  organization_id uuid references public.organizations(id) on delete restrict,
  status text not null default 'INACTIVE' check (status in ('INACTIVE', 'ACTIVE', 'SUSPENDED')),
  activation_agent_id uuid,
  preferred_agent_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, activation_agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, preferred_agent_id) references public.agents(organization_id, id) on delete restrict,
  check ((status = 'INACTIVE' and organization_id is null and activation_agent_id is null)
    or (status <> 'INACTIVE' and organization_id is not null and activation_agent_id is not null))
);

create table public.networks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 160),
  code text not null check (code ~ '^[A-Z0-9_-]{2,40}$'),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (organization_id, id)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  network_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 160),
  code text not null check (code ~ '^[A-Z0-9_-]{2,40}$'),
  value numeric(14, 4),
  price numeric(14, 2),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, network_id) references public.networks(organization_id, id) on delete restrict,
  unique (network_id, code),
  unique (organization_id, network_id, id),
  check (value is null or value >= 0),
  check (price is null or price >= 0)
);

create table public.card_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  network_id uuid not null,
  product_id uuid not null,
  source_filename text not null check (length(source_filename) between 1 and 255),
  uploaded_by uuid not null references public.profiles(user_id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  status text not null default 'REVIEW' check (status in ('REVIEW', 'APPROVED', 'CANCELLED')),
  total_rows integer not null check (total_rows >= 0),
  accepted_rows integer not null default 0 check (accepted_rows >= 0),
  rejected_rows integer not null default 0 check (rejected_rows >= 0),
  review_rows integer not null default 0 check (review_rows >= 0),
  approved_by uuid references public.profiles(user_id) on delete restrict,
  approved_at timestamptz,
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  unique (organization_id, id),
  check (accepted_rows + rejected_rows + review_rows <= total_rows),
  check ((status = 'APPROVED' and approved_at is not null and approved_by is not null)
    or (status <> 'APPROVED' and approved_at is null and approved_by is null))
);

create table public.import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.card_batches(id) on delete restrict,
  row_number integer not null check (row_number > 0),
  status text not null check (status in ('ACCEPTED', 'NEEDS_REVIEW', 'REJECTED', 'DUPLICATE_IN_FILE', 'ALREADY_EXISTS', 'INCOMPLETE')),
  credential_type text check (credential_type in ('ACCESS_CODE', 'USERNAME_PASSWORD', 'VOUCHER_CODE', 'PIN', 'OTHER')),
  credential_ciphertext bytea,
  credential_iv bytea,
  credential_fingerprint bytea,
  error_code text check (error_code is null or error_code in (
    'UNSUPPORTED_CREDENTIAL_TYPE', 'MISSING_REQUIRED_COLUMN', 'MISSING_CREDENTIAL_VALUE',
    'INVALID_ROW', 'ALREADY_EXISTS', 'DUPLICATE_IN_FILE'
  )),
  created_at timestamptz not null default now(),
  unique (batch_id, row_number),
  check (
    (status = 'ACCEPTED' and credential_type is not null and credential_ciphertext is not null and credential_iv is not null and credential_fingerprint is not null)
    or (status <> 'ACCEPTED' and credential_type is null and credential_ciphertext is null and credential_iv is null and credential_fingerprint is null)
  ),
  check (credential_ciphertext is null or octet_length(credential_ciphertext) >= 17),
  check (credential_iv is null or octet_length(credential_iv) = 12),
  check (credential_fingerprint is null or octet_length(credential_fingerprint) = 32)
);

create table public.cards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  network_id uuid not null,
  product_id uuid not null,
  batch_id uuid not null,
  credential_type text not null check (credential_type in ('ACCESS_CODE', 'USERNAME_PASSWORD', 'VOUCHER_CODE', 'PIN', 'OTHER')),
  credential_ciphertext bytea not null,
  credential_iv bytea not null,
  credential_key_version smallint not null default 1 check (credential_key_version > 0),
  credential_fingerprint bytea not null,
  possession text not null check (possession in ('QUARANTINE', 'OWNER_STOCK', 'AGENT_STOCK', 'CUSTOMER_CUSTODY', 'DISPUTED_LOST', 'RETIRED', 'COMPROMISED', 'VOIDED')),
  operation_state text not null check (operation_state in ('CREATED', 'RESERVED', 'PENDING', 'COMPLETED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  external_network_state text not null default 'UNKNOWN' check (external_network_state in ('UNKNOWN', 'VALID', 'USED', 'EXPIRED', 'CANCELLED', 'INVALID')),
  current_agent_id uuid,
  customer_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  foreign key (organization_id, batch_id) references public.card_batches(organization_id, id) on delete restrict,
  foreign key (organization_id, current_agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, customer_id) references public.customers(organization_id, id) on delete restrict,
  unique (organization_id, id),
  unique (organization_id, credential_fingerprint),
  check (possession <> 'AGENT_STOCK' or current_agent_id is not null),
  check (current_agent_id is null or possession in ('AGENT_STOCK', 'DISPUTED_LOST', 'COMPROMISED')),
  check (possession <> 'CUSTOMER_CUSTODY' or customer_id is not null),
  check (customer_id is null or possession in ('CUSTOMER_CUSTODY', 'DISPUTED_LOST', 'COMPROMISED', 'VOIDED')),
  check (octet_length(credential_ciphertext) >= 17),
  check (octet_length(credential_iv) = 12),
  check (octet_length(credential_fingerprint) = 32)
);

create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  agent_id uuid not null,
  network_id uuid not null,
  product_id uuid not null,
  status text not null check (status in ('CREATED', 'PENDING_ACCEPTANCE', 'ACCEPTED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  accepted_by uuid references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  expires_at timestamptz not null default (clock_timestamp() + interval '24 hours'),
  foreign key (organization_id, agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  unique (organization_id, id),
  check ((status = 'ACCEPTED' and accepted_at is not null and accepted_by is not null)
    or (status <> 'ACCEPTED' and accepted_at is null and accepted_by is null))
);

create table public.transfer_items (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.transfers(id) on delete restrict,
  card_id uuid not null,
  created_at timestamptz not null default now(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  foreign key (organization_id, transfer_id) references public.transfers(organization_id, id) on delete restrict,
  foreign key (organization_id, card_id) references public.cards(organization_id, id) on delete restrict,
  unique (transfer_id, card_id)
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  agent_id uuid not null,
  customer_id uuid not null,
  status text not null check (status in ('CREATED', 'RESERVED', 'PENDING', 'COMPLETED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  price numeric(14, 2) check (price is null or price >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  payment_method text,
  settlement_status text,
  discount numeric(14, 2) check (discount is null or discount >= 0),
  reason_code text,
  foreign key (organization_id, agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, customer_id) references public.customers(organization_id, id) on delete restrict,
  unique (organization_id, id),
  unique (organization_id, id, customer_id, agent_id)
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null,
  card_id uuid not null,
  created_at timestamptz not null default now(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  foreign key (organization_id, sale_id) references public.sales(organization_id, id) on delete restrict,
  foreign key (organization_id, card_id) references public.cards(organization_id, id) on delete restrict
);

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique,
  customer_id uuid not null,
  selling_agent_id uuid not null,
  status text not null check (status in ('CREATED', 'PENDING', 'COMPLETED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  foreign key (organization_id, sale_id, customer_id, selling_agent_id)
    references public.sales(organization_id, id, customer_id, agent_id) on delete restrict,
  check ((status = 'COMPLETED') = (delivered_at is not null))
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  card_id uuid not null references public.cards(id) on delete restrict,
  from_possession text check (from_possession is null or from_possession in ('QUARANTINE', 'OWNER_STOCK', 'AGENT_STOCK', 'CUSTOMER_CUSTODY', 'DISPUTED_LOST', 'RETIRED', 'COMPROMISED', 'VOIDED')),
  to_possession text not null check (to_possession in ('QUARANTINE', 'OWNER_STOCK', 'AGENT_STOCK', 'CUSTOMER_CUSTODY', 'DISPUTED_LOST', 'RETIRED', 'COMPROMISED', 'VOIDED')),
  operation_type text not null,
  operation_id uuid,
  actor_user_id uuid not null references public.profiles(user_id) on delete restrict,
  reason_code text,
  from_operation_state text check (from_operation_state is null or from_operation_state in ('CREATED', 'RESERVED', 'PENDING', 'COMPLETED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  to_operation_state text check (to_operation_state is null or to_operation_state in ('CREATED', 'RESERVED', 'PENDING', 'COMPLETED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  occurred_at timestamptz not null default now(),
  foreign key (organization_id, card_id) references public.cards(organization_id, id) on delete restrict
);

create table public.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  actor_user_id uuid not null references public.profiles(user_id) on delete restrict,
  operation_type text not null,
  idempotency_key text not null check (length(idempotency_key) between 16 and 128),
  request_fingerprint bytea not null,
  operation_id uuid,
  response jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id, actor_user_id, operation_type, idempotency_key)
);

create table public.claim_tokens (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  token_fingerprint bytea not null unique,
  expires_at timestamptz not null,
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  actor_user_id uuid references public.profiles(user_id) on delete set null,
  action text not null,
  target_type text not null,
  target_id uuid,
  operation_id uuid,
  result text not null check (result in ('SUCCESS', 'FAILURE', 'PENDING', 'UNKNOWN')),
  reason_code text,
  trace_id uuid not null,
  occurred_at timestamptz not null default now()
);

create table public.security_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete restrict,
  actor_user_id uuid references public.profiles(user_id) on delete set null,
  event_type text not null check (event_type in ('LOGIN_SUCCESS', 'LOGIN_FAILURE', 'CREDENTIAL_REVEAL', 'PASSWORD_CHANGE', 'SESSION_REVOKE', 'SUSPICIOUS_ACTIVITY', 'SENSITIVE_ACTION')),
  target_id uuid,
  result text not null check (result in ('SUCCESS', 'FAILURE', 'PENDING', 'UNKNOWN')),
  trace_id uuid not null,
  occurred_at timestamptz not null default now()
);

create table public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  device_label text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table public.app_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  auth_session_id uuid not null unique,
  device_id uuid references public.user_devices(id) on delete set null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete restrict,
  recipient_user_id uuid not null references public.profiles(user_id) on delete cascade,
  channel text not null check (channel in ('EMAIL', 'SMS', 'PUSH')),
  template_key text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING' check (status in ('PENDING', 'PROCESSING', 'SENT', 'FAILED', 'CANCELLED')),
  attempts integer not null default 0 check (attempts >= 0),
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create index memberships_user_role_idx on public.memberships (user_id, role, organization_id);
create index customers_org_status_idx on public.customers (organization_id, status);
create index networks_org_status_idx on public.networks (organization_id, status);
create index products_network_status_idx on public.products (network_id, status);
create index card_batches_org_uploaded_idx on public.card_batches (organization_id, uploaded_at desc, id);
create index import_rows_batch_status_idx on public.import_rows (batch_id, status, row_number);
create index cards_owner_fifo_idx on public.cards (organization_id, product_id, created_at, id) where possession = 'OWNER_STOCK' and operation_state = 'COMPLETED';
create index cards_agent_fifo_idx on public.cards (organization_id, current_agent_id, product_id, created_at, id) where possession = 'AGENT_STOCK' and operation_state = 'COMPLETED';
create index cards_customer_idx on public.cards (customer_id, created_at desc, id) where possession = 'CUSTOMER_CUSTODY';
create index transfers_agent_status_idx on public.transfers (organization_id, agent_id, status, created_at desc);
create index transfers_expiry_idx on public.transfers (organization_id, expires_at, id) where status = 'PENDING_ACCEPTANCE';
create index sales_agent_created_idx on public.sales (organization_id, agent_id, created_at desc, id);
create index sales_customer_created_idx on public.sales (customer_id, created_at desc, id);
create index inventory_movements_card_idx on public.inventory_movements (card_id, occurred_at, id);
create index audit_events_org_time_idx on public.audit_events (organization_id, occurred_at desc, id);
create index security_events_user_time_idx on public.security_events (actor_user_id, occurred_at desc, id);
create index notification_outbox_pending_idx on public.notification_outbox (created_at, id) where status = 'PENDING';

create or replace function private.has_org_role(p_organization_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.organization_id = p_organization_id
      and m.user_id = (select auth.uid())
      and m.role = any(p_roles)
  );
$$;

create or replace function private.is_self(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select p_user_id = (select auth.uid()); $$;

revoke all on function private.has_org_role(uuid, text[]) from public, anon;
revoke all on function private.is_self(uuid) from public, anon;
grant execute on function private.has_org_role(uuid, text[]) to authenticated;
grant execute on function private.is_self(uuid) to authenticated;

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  user_phone text;
  display_name text;
begin
  user_phone := new.raw_user_meta_data ->> 'phone';
  display_name := new.raw_user_meta_data ->> 'display_name';
  if user_phone is null or user_phone !~ '^7[0-9]{8}$'
     or new.email is distinct from (user_phone || '@mutahidun.app')
     or display_name is null or length(btrim(display_name)) not between 1 and 160 then
    raise exception 'invalid_signup_metadata' using errcode = '22023';
  end if;
  insert into public.profiles (user_id, display_name, phone)
    values (new.id, btrim(display_name), user_phone);
  insert into public.customers (user_id) values (new.id);
  return new;
end;
$$;

revoke all on function private.handle_new_auth_user() from public, anon, authenticated;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.memberships enable row level security;
alter table public.agents enable row level security;
alter table public.customers enable row level security;
alter table public.networks enable row level security;
alter table public.products enable row level security;
alter table public.card_batches enable row level security;
alter table public.import_rows enable row level security;
alter table public.cards enable row level security;
alter table public.transfers enable row level security;
alter table public.transfer_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.deliveries enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.idempotency_keys enable row level security;
alter table public.claim_tokens enable row level security;
alter table public.audit_events enable row level security;
alter table public.security_events enable row level security;
alter table public.user_devices enable row level security;
alter table public.app_sessions enable row level security;
alter table public.notification_outbox enable row level security;

create policy organizations_member_read on public.organizations for select to authenticated
  using (private.has_org_role(id, array['OWNER','ADMIN','AGENT','CUSTOMER']::text[]));
create policy profiles_self_read on public.profiles for select to authenticated
  using (private.is_self(user_id));
create policy profiles_org_admin_read on public.profiles for select to authenticated
  using (exists (select 1 from public.memberships own join public.memberships other using (organization_id)
    where own.user_id = (select auth.uid()) and own.role in ('OWNER','ADMIN') and other.user_id = profiles.user_id));
create policy memberships_self_or_admin_read on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or private.has_org_role(organization_id, array['OWNER','ADMIN']::text[]));
create policy agents_org_read on public.agents for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN','AGENT']::text[]));
create policy customers_self_read on public.customers for select to authenticated
  using (user_id = (select auth.uid()));
create policy customers_org_read on public.customers for select to authenticated
  using (
    private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
    or exists (select 1 from public.agents a where a.organization_id = customers.organization_id
      and a.user_id = (select auth.uid()) and a.active
      and private.has_org_role(customers.organization_id, array['AGENT']::text[])
      and a.id in (customers.activation_agent_id, customers.preferred_agent_id))
  );
create policy networks_org_read on public.networks for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN','AGENT','CUSTOMER']::text[]));
create policy products_org_read on public.products for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN','AGENT','CUSTOMER']::text[]));
create policy batches_admin_read on public.card_batches for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[]));
create policy rows_admin_read on public.import_rows for select to authenticated
  using (exists (select 1 from public.card_batches b where b.id = batch_id
    and private.has_org_role(b.organization_id, array['OWNER','ADMIN']::text[])));
create policy cards_scoped_read on public.cards for select to authenticated using (
  private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
  or exists (select 1 from public.agents a where a.id = current_agent_id and a.organization_id = cards.organization_id
    and a.user_id = (select auth.uid()) and a.active
    and private.has_org_role(cards.organization_id, array['AGENT']::text[]))
  or exists (select 1 from public.customers c where c.id = cards.customer_id
    and c.organization_id = cards.organization_id and c.user_id = (select auth.uid()) and c.status = 'ACTIVE'
    and private.has_org_role(cards.organization_id, array['CUSTOMER']::text[]))
);
create policy transfers_scoped_read on public.transfers for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
    or exists (select 1 from public.agents a where a.id = transfers.agent_id and a.organization_id = transfers.organization_id
      and a.user_id = (select auth.uid()) and a.active
      and private.has_org_role(transfers.organization_id, array['AGENT']::text[])));
create policy transfer_items_scoped_read on public.transfer_items for select to authenticated
  using (exists (select 1 from public.transfers t where t.id = transfer_id
    and (private.has_org_role(t.organization_id, array['OWNER','ADMIN']::text[])
      or exists (select 1 from public.agents a where a.id = t.agent_id and a.organization_id = t.organization_id
        and a.user_id = (select auth.uid()) and a.active
        and private.has_org_role(t.organization_id, array['AGENT']::text[])))));
create policy sales_scoped_read on public.sales for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
    or (created_by = (select auth.uid()) and private.has_org_role(organization_id, array['AGENT']::text[]))
    or exists (select 1 from public.customers c where c.id = sales.customer_id
      and c.organization_id = sales.organization_id and c.user_id = (select auth.uid()) and c.status = 'ACTIVE'
      and private.has_org_role(sales.organization_id, array['CUSTOMER']::text[])));
create policy sale_items_scoped_read on public.sale_items for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id
    and (private.has_org_role(s.organization_id, array['OWNER','ADMIN']::text[])
      or (s.created_by = (select auth.uid()) and private.has_org_role(s.organization_id, array['AGENT']::text[]))
      or exists (select 1 from public.customers c where c.id = s.customer_id and c.organization_id = s.organization_id
        and c.user_id = (select auth.uid()) and c.status = 'ACTIVE'
        and private.has_org_role(s.organization_id, array['CUSTOMER']::text[])))));
create policy deliveries_scoped_read on public.deliveries for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id
    and (private.has_org_role(s.organization_id, array['OWNER','ADMIN']::text[])
      or (s.created_by = (select auth.uid()) and private.has_org_role(s.organization_id, array['AGENT']::text[]))
      or exists (select 1 from public.customers c where c.id = s.customer_id and c.organization_id = s.organization_id
        and c.user_id = (select auth.uid()) and c.status = 'ACTIVE'
        and private.has_org_role(s.organization_id, array['CUSTOMER']::text[])))));
create policy movements_admin_read on public.inventory_movements for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[]));
create policy idempotency_actor_read on public.idempotency_keys for select to authenticated
  using (actor_user_id = (select auth.uid())
    and private.has_org_role(organization_id, array['OWNER','ADMIN','AGENT','CUSTOMER']::text[]));
create policy audit_admin_read on public.audit_events for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[]));
create policy security_admin_read on public.security_events for select to authenticated
  using ((actor_user_id = (select auth.uid()) and (organization_id is null
      or private.has_org_role(organization_id, array['OWNER','ADMIN','AGENT','CUSTOMER']::text[]))) or (organization_id is not null
    and private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])));
create policy devices_self_read on public.user_devices for select to authenticated
  using (user_id = (select auth.uid()));
create policy sessions_self_read on public.app_sessions for select to authenticated
  using (user_id = (select auth.uid()));

-- No direct writes are granted. Mutations are performed only by reviewed RPC functions.
revoke all on all tables in schema public from anon, authenticated;
grant select on public.organizations, public.profiles, public.memberships, public.agents,
  public.customers, public.networks, public.products, public.card_batches, public.import_rows,
  public.transfers, public.transfer_items, public.sales, public.sale_items, public.deliveries,
  public.inventory_movements, public.idempotency_keys, public.audit_events,
  public.security_events, public.user_devices, public.app_sessions to authenticated;
grant select (id, organization_id, network_id, product_id, batch_id, possession,
  operation_state, external_network_state, current_agent_id, customer_id, created_at, updated_at)
  on public.cards to authenticated;

alter default privileges in schema public revoke all on tables from anon, authenticated;
