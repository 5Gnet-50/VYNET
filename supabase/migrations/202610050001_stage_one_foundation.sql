-- Additive Stage 1 foundation. This migration preserves the legacy single-line
-- transfer columns while introducing request, multi-line transfer, ledger,
-- and internal notification records.
begin;

-- Uncertain source classification belongs in review metadata, not guessed inventory.
alter table public.card_batches alter column network_id drop not null;
alter table public.card_batches alter column product_id drop not null;
alter table public.card_batches
  add constraint card_batches_classification_pair_check
    check (product_id is null or network_id is not null);

alter table public.transfers
  add column operation_id uuid not null default gen_random_uuid(),
  add column request_id uuid,
  add column executed_by uuid references public.profiles(user_id) on delete restrict,
  add column sent_at timestamptz;
alter table public.transfers alter column network_id drop not null;
alter table public.transfers alter column product_id drop not null;
create unique index transfers_operation_id_uidx on public.transfers(operation_id);

create table public.transfer_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operation_id uuid not null default gen_random_uuid(),
  agent_id uuid not null,
  requested_by uuid not null references public.profiles(user_id) on delete restrict,
  status text not null default 'SUBMITTED'
    check (status in ('SUBMITTED', 'UNDER_REVIEW', 'APPROVED', 'REJECTED', 'TRANSFERRED', 'CANCELLED')),
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(user_id) on delete restrict,
  reviewed_at timestamptz,
  decision_reason text,
  trace_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, agent_id) references public.agents(organization_id, id) on delete restrict,
  unique (organization_id, id),
  unique (operation_id),
  check ((status in ('APPROVED', 'REJECTED', 'TRANSFERRED') and reviewed_at is not null and reviewed_by is not null)
    or status in ('SUBMITTED', 'UNDER_REVIEW', 'CANCELLED'))
);

create table public.transfer_request_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  request_id uuid not null,
  network_id uuid not null,
  product_id uuid not null,
  requested_quantity integer not null check (requested_quantity > 0),
  approved_quantity integer check (approved_quantity is null or approved_quantity >= 0),
  created_at timestamptz not null default now(),
  foreign key (organization_id, request_id) references public.transfer_requests(organization_id, id) on delete restrict,
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  unique (request_id, product_id),
  unique (organization_id, request_id, id)
);

create table public.transfer_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  transfer_id uuid not null,
  request_line_id uuid,
  network_id uuid not null,
  product_id uuid not null,
  requested_quantity integer check (requested_quantity is null or requested_quantity > 0),
  approved_quantity integer check (approved_quantity is null or approved_quantity > 0),
  actual_quantity integer not null check (actual_quantity >= 0),
  agent_unit_price numeric(14,2) check (agent_unit_price is null or agent_unit_price >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, transfer_id) references public.transfers(organization_id, id) on delete restrict,
  foreign key (organization_id, request_line_id) references public.transfer_request_lines(organization_id, id) on delete restrict,
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  unique (organization_id, transfer_id, id),
  unique (transfer_id, product_id),
  check ((agent_unit_price is null and currency is null) or (agent_unit_price is not null and currency is not null))
);

alter table public.transfers
  add constraint transfers_request_fk foreign key (organization_id, request_id)
    references public.transfer_requests(organization_id, id) on delete restrict;

alter table public.transfer_items add column transfer_line_id uuid;

-- Preserve the already-recorded actual card allocations for legacy one-line transfers.
with legacy_counts as (
  select t.id as transfer_id, t.organization_id, t.network_id, t.product_id,
    count(ti.id)::integer as actual_quantity
  from public.transfers t
  join public.transfer_items ti on ti.transfer_id = t.id
  where t.product_id is not null and t.network_id is not null
  group by t.id, t.organization_id, t.network_id, t.product_id
)
insert into public.transfer_lines (
  organization_id, transfer_id, network_id, product_id,
  requested_quantity, approved_quantity, actual_quantity, executed_at
)
select organization_id, transfer_id, network_id, product_id,
  actual_quantity, actual_quantity, actual_quantity,
  (select t.sent_at from public.transfers t where t.id = transfer_id)
from legacy_counts
on conflict (transfer_id, product_id) do nothing;

update public.transfer_items ti
set transfer_line_id = tl.id
from public.transfer_lines tl
where tl.transfer_id = ti.transfer_id and tl.organization_id = ti.organization_id;

alter table public.transfer_items
  add constraint transfer_items_line_fk foreign key (organization_id, transfer_id, transfer_line_id)
    references public.transfer_lines(organization_id, transfer_id, id) on delete restrict;
create index transfer_request_agent_status_idx
  on public.transfer_requests(organization_id, agent_id, status, submitted_at desc, id);
create index transfer_request_lines_request_idx on public.transfer_request_lines(request_id, product_id);
create index transfer_lines_product_idx on public.transfer_lines(organization_id, product_id, transfer_id);
create index transfer_items_line_idx on public.transfer_items(transfer_line_id, card_id);

create table public.financial_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  agent_id uuid not null,
  operation_id uuid not null,
  transfer_id uuid,
  related_entry_id uuid references public.financial_entries(id) on delete restrict,
  entry_type text not null check (entry_type in ('TRANSFER_VALUE', 'PAYMENT_RECEIVED', 'ADJUSTMENT', 'REVERSAL')),
  amount numeric(14,2) not null check (amount >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  occurred_at timestamptz not null default now(),
  actor_user_id uuid references public.profiles(user_id) on delete set null,
  trace_id uuid not null,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  foreign key (organization_id, agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, transfer_id) references public.transfers(organization_id, id) on delete restrict,
  unique (organization_id, id)
);
create index financial_entries_agent_time_idx
  on public.financial_entries(organization_id, agent_id, occurred_at desc, id);
create index financial_entries_operation_idx on public.financial_entries(operation_id, occurred_at, id);
create unique index financial_entries_transfer_value_uidx
  on public.financial_entries(transfer_id, agent_id, entry_type)
  where transfer_id is not null and entry_type = 'TRANSFER_VALUE';

create function private.reject_immutable_row_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'APPEND_ONLY_RECORD' using errcode = '42501';
end;
$$;
create trigger financial_entries_append_only
  before update or delete on public.financial_entries
  for each row execute function private.reject_immutable_row_change();
create trigger inventory_movements_append_only
  before update or delete on public.inventory_movements
  for each row execute function private.reject_immutable_row_change();
create trigger audit_events_append_only
  before update or delete on public.audit_events
  for each row execute function private.reject_immutable_row_change();
create trigger transfer_lines_append_only
  before update or delete on public.transfer_lines
  for each row execute function private.reject_immutable_row_change();

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete restrict,
  recipient_user_id uuid not null references public.profiles(user_id) on delete cascade,
  operation_id uuid,
  notification_type text not null check (length(btrim(notification_type)) between 1 and 80),
  title text not null check (length(btrim(title)) between 1 and 200),
  body text not null check (length(body) <= 1000),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_recipient_unread_idx
  on public.notifications(recipient_user_id, created_at desc, id) where read_at is null;
alter table public.notification_outbox
  add column operation_id uuid,
  add column notification_id uuid references public.notifications(id) on delete set null;

create or replace function private.submit_agent_transfer_request_impl(
  p_organization_id uuid, p_lines jsonb, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  agent uuid;
  request_id uuid := gen_random_uuid();
  operation uuid := gen_random_uuid();
  request_hash bytea;
  replay jsonb;
  result jsonb;
  line_count integer;
  inserted_count integer;
begin
  if actor is null or p_lines is null or jsonb_typeof(p_lines) <> 'array'
    or jsonb_array_length(p_lines) < 1 then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_REQUEST');
  end if;
  select a.id into agent from public.agents a
  where a.organization_id = p_organization_id and a.user_id = actor and a.active
    and private.has_org_role(p_organization_id, array['AGENT']::text[]);
  if agent is null then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;

  request_hash := extensions.digest(convert_to(p_organization_id::text || ':' || p_lines::text, 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_REQUEST', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select count(*) into line_count from jsonb_to_recordset(p_lines) as line(product_id uuid, quantity integer);
  if line_count <> jsonb_array_length(p_lines)
    or exists (select 1 from jsonb_to_recordset(p_lines) as line(product_id uuid, quantity integer)
      where line.product_id is null or line.quantity is null or line.quantity < 1)
    or exists (select 1 from jsonb_to_recordset(p_lines) as line(product_id uuid, quantity integer)
      group by line.product_id having count(*) > 1)
    or exists (select 1 from jsonb_to_recordset(p_lines) as line(product_id uuid, quantity integer)
      left join public.products p on p.id = line.product_id and p.organization_id = p_organization_id and p.status = 'ACTIVE'
      where p.id is null) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'INVALID_REQUEST_LINES');
  else
    insert into public.transfer_requests (id, organization_id, operation_id, agent_id, requested_by, trace_id)
    values (request_id, p_organization_id, operation, agent, actor, p_trace_id);
    insert into public.transfer_request_lines (organization_id, request_id, network_id, product_id, requested_quantity)
    select p_organization_id, request_id, p.network_id, line.product_id, line.quantity
    from jsonb_to_recordset(p_lines) as line(product_id uuid, quantity integer)
    join public.products p on p.id = line.product_id and p.organization_id = p_organization_id and p.status = 'ACTIVE';
    get diagnostics inserted_count = row_count;
    if inserted_count <> line_count then raise exception 'request_line_insert_mismatch'; end if;

    insert into public.notifications (organization_id, recipient_user_id, operation_id, notification_type, title, body, payload)
    select p_organization_id, m.user_id, operation, 'TRANSFER_REQUEST', 'طلب بطاقات جديد',
      'أرسل وكيل طلب بطاقات جديدًا للمراجعة.', jsonb_build_object('request_id', request_id)
    from public.memberships m where m.organization_id = p_organization_id and m.role in ('OWNER','ADMIN');
    perform private.write_audit(p_organization_id, actor, 'TRANSFER_REQUEST_SUBMITTED', 'TRANSFER_REQUEST', request_id,
      operation, 'SUCCESS', null, p_trace_id);
    result := jsonb_build_object('status', 'SUCCESS', 'request_id', request_id, 'operation_id', operation);
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_REQUEST', p_idempotency_key, operation, result);
  return result;
end;
$$;

create or replace function public.submit_agent_transfer_request(
  p_organization_id uuid, p_lines jsonb, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security invoker set search_path = '' as $$
  select private.submit_agent_transfer_request_impl(p_organization_id, p_lines, p_idempotency_key, p_trace_id);
$$;

create or replace function private.decide_transfer_request_impl(
  p_organization_id uuid, p_request_id uuid, p_decision text, p_approved_lines jsonb,
  p_reason text, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  request public.transfer_requests%rowtype;
  request_hash bytea;
  replay jsonb;
  result jsonb;
  line_count integer;
  decision_count integer;
  recipient uuid;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[])
    or p_decision is null or p_decision not in ('APPROVED','REJECTED') or p_approved_lines is null
    or jsonb_typeof(p_approved_lines) <> 'array' then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED_OR_INVALID_DECISION');
  end if;
  request_hash := extensions.digest(convert_to(concat_ws(':', p_organization_id, p_request_id, p_decision,
    p_approved_lines::text, coalesce(p_reason, '')), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_REQUEST_DECISION', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select * into request from public.transfer_requests r
  where r.id = p_request_id and r.organization_id = p_organization_id for update;
  if not found or request.status not in ('SUBMITTED','UNDER_REVIEW') then
    result := jsonb_build_object('status', 'FAILED', 'code', 'REQUEST_NOT_REVIEWABLE');
  elsif p_decision = 'REJECTED' and (jsonb_array_length(p_approved_lines) <> 0 or length(btrim(coalesce(p_reason, ''))) = 0) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'REJECTION_REASON_REQUIRED');
  else
    select count(*) into line_count from public.transfer_request_lines l where l.request_id = request.id;
    select count(*) into decision_count from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer);
    if p_decision = 'APPROVED' and (
      decision_count <> line_count
      or exists (select 1 from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer)
        where d.product_id is null or d.approved_quantity is null or d.approved_quantity < 0)
      or exists (select 1 from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer)
        group by d.product_id having count(*) > 1)
      or exists (select 1 from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer)
        left join public.transfer_request_lines l on l.request_id = request.id and l.product_id = d.product_id
        where l.id is null or d.approved_quantity > l.requested_quantity)
      or not exists (select 1 from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer)
        where d.approved_quantity > 0)
    ) then
      result := jsonb_build_object('status', 'FAILED', 'code', 'INVALID_APPROVED_QUANTITIES');
    else
      if p_decision = 'APPROVED' then
        update public.transfer_request_lines l set approved_quantity = d.approved_quantity
        from jsonb_to_recordset(p_approved_lines) as d(product_id uuid, approved_quantity integer)
        where l.request_id = request.id and l.product_id = d.product_id;
      end if;
      update public.transfer_requests set status = p_decision, reviewed_by = actor, reviewed_at = now(),
        decision_reason = nullif(left(btrim(coalesce(p_reason, '')), 500), ''), updated_at = now()
      where id = request.id;
      select a.user_id into recipient from public.agents a where a.id = request.agent_id;
      insert into public.notifications (organization_id, recipient_user_id, operation_id, notification_type, title, body, payload)
      values (p_organization_id, recipient, request.operation_id,
        case when p_decision = 'APPROVED' then 'TRANSFER_REQUEST_APPROVED' else 'TRANSFER_REQUEST_REJECTED' end,
        case when p_decision = 'APPROVED' then 'تمت مراجعة طلب البطاقات' else 'تم رفض طلب البطاقات' end,
        case when p_decision = 'APPROVED' then 'وافق المالك على الطلب. سيظهر التحويل بعد تنفيذه.' else 'راجع سبب القرار في تفاصيل الطلب.' end,
        jsonb_build_object('request_id', request.id));
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_REQUEST_' || p_decision,
        'TRANSFER_REQUEST', request.id, request.operation_id, 'SUCCESS', nullif(p_reason, ''), p_trace_id);
      result := jsonb_build_object('status', 'SUCCESS', 'request_id', request.id, 'decision', p_decision);
    end if;
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_REQUEST_DECISION', p_idempotency_key,
    coalesce(request.operation_id, p_request_id), result);
  return result;
end;
$$;

create or replace function public.decide_transfer_request(
  p_organization_id uuid, p_request_id uuid, p_decision text, p_approved_lines jsonb,
  p_reason text, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security invoker set search_path = '' as $$
  select private.decide_transfer_request_impl(p_organization_id, p_request_id, p_decision,
    p_approved_lines, p_reason, p_idempotency_key, p_trace_id);
$$;

alter table public.card_batches
  add column source_file_ref text,
  add column source_content_type text,
  add column source_file_size_bytes bigint check (source_file_size_bytes is null or source_file_size_bytes between 1 and 50000000),
  add column source_sha256 bytea check (source_sha256 is null or octet_length(source_sha256) = 32),
  add column classification_confidence numeric(5,4) check (classification_confidence is null or classification_confidence between 0 and 1),
  add column processing_status text not null default 'REVIEW'
    check (processing_status in ('UPLOADED', 'PROCESSING', 'REVIEW', 'READY', 'APPROVED', 'REJECTED', 'FAILED'));

alter table public.audit_events
  add column target_card_id uuid,
  add column source_ref text,
  add column destination_ref text,
  add column quantity bigint check (quantity is null or quantity >= 0),
  add column state_before jsonb check (state_before is null or jsonb_typeof(state_before) = 'object'),
  add column state_after jsonb check (state_after is null or jsonb_typeof(state_after) = 'object');
alter table public.audit_events
  add constraint audit_events_target_card_fk foreign key (organization_id, target_card_id)
    references public.cards(organization_id, id) on delete restrict;

alter table public.transfer_requests enable row level security;
alter table public.transfer_request_lines enable row level security;
alter table public.transfer_lines enable row level security;
alter table public.financial_entries enable row level security;
alter table public.notifications enable row level security;

create policy transfer_requests_scoped_read on public.transfer_requests for select to authenticated using (
  private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
  or exists (select 1 from public.agents a where a.id = agent_id and a.user_id = (select auth.uid()) and a.active
    and private.has_org_role(organization_id, array['AGENT']::text[]))
);
create policy transfer_request_lines_scoped_read on public.transfer_request_lines for select to authenticated using (
  exists (select 1 from public.transfer_requests r where r.id = transfer_request_lines.request_id
    and r.organization_id = transfer_request_lines.organization_id
    and (private.has_org_role(transfer_request_lines.organization_id, array['OWNER','ADMIN']::text[])
      or exists (select 1 from public.agents a where a.id = r.agent_id and a.user_id = (select auth.uid()) and a.active
        and private.has_org_role(transfer_request_lines.organization_id, array['AGENT']::text[]))))
);
create policy transfer_lines_scoped_read on public.transfer_lines for select to authenticated using (
  private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
  or exists (select 1 from public.transfers t join public.agents a on a.id = t.agent_id
    where t.id = transfer_id and a.user_id = (select auth.uid()) and a.active
      and private.has_org_role(organization_id, array['AGENT']::text[]))
);
create policy financial_entries_scoped_read on public.financial_entries for select to authenticated using (
  private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
  or exists (select 1 from public.agents a where a.id = agent_id and a.user_id = (select auth.uid()) and a.active
    and private.has_org_role(organization_id, array['AGENT']::text[]))
);
create policy notifications_recipient_read on public.notifications for select to authenticated
  using (recipient_user_id = (select auth.uid()));
create policy notifications_recipient_mark_read on public.notifications for update to authenticated
  using (recipient_user_id = (select auth.uid())) with check (recipient_user_id = (select auth.uid()));

revoke all on public.transfer_requests, public.transfer_request_lines, public.transfer_lines,
  public.financial_entries, public.notifications from anon, authenticated;
grant select on public.transfer_requests, public.transfer_request_lines, public.transfer_lines,
  public.financial_entries, public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
revoke all on function private.reject_immutable_row_change() from public, anon, authenticated;
revoke all on function private.submit_agent_transfer_request_impl(uuid, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function public.submit_agent_transfer_request(uuid, jsonb, text, uuid) from public, anon;
grant execute on function private.submit_agent_transfer_request_impl(uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.submit_agent_transfer_request(uuid, jsonb, text, uuid) to authenticated;
revoke all on function private.decide_transfer_request_impl(uuid, uuid, text, jsonb, text, text, uuid) from public, anon, authenticated;
revoke all on function public.decide_transfer_request(uuid, uuid, text, jsonb, text, text, uuid) from public, anon;
grant execute on function private.decide_transfer_request_impl(uuid, uuid, text, jsonb, text, text, uuid) to authenticated;
grant execute on function public.decide_transfer_request(uuid, uuid, text, jsonb, text, text, uuid) to authenticated;
-- Disable the old direct owner transfer entry point. It reserves cards immediately
-- and cannot satisfy the approved request -> review -> approval -> execution flow.
revoke all on function public.create_owner_agent_transfer(uuid, uuid, uuid, uuid, integer, text, uuid) from public, anon, authenticated;
revoke all on function private.create_owner_agent_transfer_impl(uuid, uuid, uuid, uuid, integer, text, uuid) from public, anon, authenticated;

commit;
