-- Repair the Stage 1 row-level security policies using unambiguous outer-row references.
-- This forward migration is for databases where Stage 1 has already been recorded.
begin;

drop policy if exists transfer_requests_scoped_read on public.transfer_requests;
create policy transfer_requests_scoped_read
on public.transfer_requests for select to authenticated
using (
  private.has_org_role(transfer_requests.organization_id, array['OWNER','ADMIN']::text[])
  or exists (
    select 1
    from public.agents as a
    where a.id = transfer_requests.agent_id
      and a.user_id = (select auth.uid())
      and a.active
      and private.has_org_role(transfer_requests.organization_id, array['AGENT']::text[])
  )
);

drop policy if exists transfer_lines_scoped_read on public.transfer_lines;
create policy transfer_lines_scoped_read
on public.transfer_lines for select to authenticated
using (
  private.has_org_role(public.transfer_lines.organization_id, array['OWNER','ADMIN']::text[])
  or exists (
    select 1
    from public.transfers as t
    join public.agents as a on a.id = t.agent_id
    where t.id = public.transfer_lines.transfer_id
      and a.user_id = (select auth.uid())
      and a.active
      and private.has_org_role(public.transfer_lines.organization_id, array['AGENT']::text[])
  )
);

drop policy if exists financial_entries_scoped_read on public.financial_entries;
create policy financial_entries_scoped_read
on public.financial_entries for select to authenticated
using (
  private.has_org_role(financial_entries.organization_id, array['OWNER','ADMIN']::text[])
  or exists (
    select 1
    from public.agents as a
    where a.id = financial_entries.agent_id
      and a.user_id = (select auth.uid())
      and a.active
      and private.has_org_role(financial_entries.organization_id, array['AGENT']::text[])
  )
);

commit;
