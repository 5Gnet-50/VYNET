import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { canReverseWrongDelivery, canTransitionOperation, canTransitionPossession, selectAgentStockForSale, selectOwnerStockForTransfer } from "../src/lib/domain/cards";
import { isValidPassword, isValidPhone, phoneToInternalAuthEmail } from "../src/lib/domain/identity";
import { canGrantMembershipRole, resolveVynetExperience } from "../src/lib/domain/authorization";
import { canAcceptTransfer, expireTransferState, validateApprovedTransferLines, validateTransferRequestLines } from "../src/lib/domain/transfers";
import { parseCardCsv } from "../src/lib/imports/csv";
import { decryptCardCredential, encryptCardCredential, fingerprintCardCredential } from "../src/lib/security/card-credentials";

const fingerprintKey = Buffer.alloc(32, 3).toString("base64");
const encryptionKey = Buffer.alloc(32, 7).toString("base64");
const coreSql = readFileSync(join(process.cwd(), "supabase/migrations/202610040001_core_schema.sql"), "utf8");
const operationsSql = readFileSync(join(process.cwd(), "supabase/migrations/202610040002_operations.sql"), "utf8");
const stageOneSql = readFileSync(join(process.cwd(), "supabase/migrations/202610050001_stage_one_foundation.sql"), "utf8");
const finalizationSql = readFileSync(join(process.cwd(), "supabase/migrations/202610060001_stage_one_finalization.sql"), "utf8");

test("phone validation and the single internal email mapping are exact", () => {
  assert.equal(isValidPhone("712345678"), true);
  assert.equal(isValidPhone("812345678"), false);
  assert.equal(isValidPhone("71234567"), false);
  assert.equal(isValidPhone("7123456780"), false);
  assert.equal(phoneToInternalAuthEmail("712345678"), "712345678@vynet.app");
  assert.throws(() => phoneToInternalAuthEmail("+967712345678"), /INVALID_PHONE/);
});

test("multi-category transfer request quantities are validated without reserving inventory", () => {
  const requested = [{ productId: "p500", quantity: 100 }, { productId: "p1000", quantity: 50 }];
  assert.equal(validateTransferRequestLines(requested), true);
  assert.equal(validateTransferRequestLines([{ productId: "p500", quantity: 0 }]), false);
  assert.equal(validateTransferRequestLines([{ productId: "p500", quantity: 1 }, { productId: "p500", quantity: 2 }]), false);
  assert.equal(validateApprovedTransferLines(requested, [
    { productId: "p500", approvedQuantity: 80 }, { productId: "p1000", approvedQuantity: 50 },
  ]), true);
  assert.equal(validateApprovedTransferLines(requested, [
    { productId: "p500", approvedQuantity: 0 }, { productId: "p1000", approvedQuantity: 50 },
  ]), true);
  assert.equal(validateApprovedTransferLines(requested, [
    { productId: "p500", approvedQuantity: 0 }, { productId: "p1000", approvedQuantity: 0 },
  ]), false);
  assert.equal(validateApprovedTransferLines(requested, [{ productId: "p500", approvedQuantity: 100 }]), false);
  assert.equal(validateApprovedTransferLines(requested, [
    { productId: "p500", approvedQuantity: 101 }, { productId: "p1000", approvedQuantity: 50 },
  ]), false);
});

test("VYNET resolves owner and agent experiences without exposing a role selector", () => {
  assert.equal(resolveVynetExperience(["OWNER"]), "OWNER_ADMIN");
  assert.equal(resolveVynetExperience(["ADMIN"]), "OWNER_ADMIN");
  assert.equal(resolveVynetExperience(["AGENT"]), "AGENT");
  assert.equal(resolveVynetExperience([]), "UNAUTHORIZED");
  assert.equal(resolveVynetExperience(["OWNER", "AGENT"]), "AMBIGUOUS");
});

test("stage one schema separates transfer requests, executed lines, finance, and inbox notifications", () => {
  assert.match(stageOneSql, /create table public\.transfer_requests/i);
  assert.match(stageOneSql, /create table public\.transfer_request_lines/i);
  assert.match(stageOneSql, /create table public\.transfer_lines/i);
  assert.match(stageOneSql, /create table public\.financial_entries/i);
  assert.match(stageOneSql, /create table public\.notifications/i);
  assert.match(stageOneSql, /add column transfer_line_id uuid/i);
  assert.match(stageOneSql, /financial_entries_append_only/i);
  assert.match(stageOneSql, /inventory_movements_append_only/i);
  assert.match(stageOneSql, /notifications_recipient_read/i);
  assert.match(stageOneSql, /create or replace function public\.submit_agent_transfer_request/i);
  assert.match(stageOneSql, /create or replace function public\.decide_transfer_request/i);
  assert.match(stageOneSql, /revoke all on function public\.create_owner_agent_transfer[\s\S]*?from public, anon, authenticated/i);
  const requestSubmit = stageOneSql.split("create or replace function private.submit_agent_transfer_request_impl(")[1]
    ?.split("create or replace function public.submit_agent_transfer_request(")[0] ?? "";
  assert.ok(requestSubmit.length > 0);
  assert.doesNotMatch(requestSubmit, /insert into public\.transfers|update public\.cards|TRANSFER_RESERVATION/i);
});

test("stage one finalization pins VYNET auth, per-agent pricing, and atomic approved transfer execution", () => {
  assert.match(finalizationSql, /new\.email is distinct from \(user_phone \|\| '@vynet\.app'\)/i);
  assert.match(finalizationSql, /Membership and agent records are provisioned by governed admin\/bootstrap flows/i);
  assert.match(finalizationSql, /create table public\.agent_product_prices/i);
  assert.match(finalizationSql, /unique \(organization_id, agent_id, network_id, product_id\)/i);
  assert.match(finalizationSql, /create or replace function public\.set_agent_product_price/i);
  assert.match(finalizationSql, /create or replace function public\.execute_approved_transfer/i);
  assert.match(finalizationSql, /for update skip locked/i);
  assert.match(finalizationSql, /financial_entries_transfer_line_value_uidx/i);
  assert.match(finalizationSql, /price\.unit_price,\s*line\.approved_quantity, price\.currency/i);
  assert.match(finalizationSql, /create or replace function private\.accept_owner_agent_transfer_impl/i);
  assert.match(finalizationSql, /TRANSFER_READY_FOR_ACCEPTANCE/i);
  assert.match(finalizationSql, /TRANSFER_ACCEPTED/i);
  assert.match(finalizationSql, /revoke all on function public\.issue_customer_claim_token\(\) from public, anon, authenticated/i);
  assert.match(finalizationSql, /revoke all on function public\.activate_customer_with_claim_token\(text, uuid, uuid\) from public, anon, authenticated/i);
  assert.match(finalizationSql, /rollback|raise exception 'insufficient_owner_inventory'/i);
});

test("password validation accepts six characters and rejects shorter values", () => {
  assert.equal(isValidPassword("12345"), false);
  assert.equal(isValidPassword("123456"), true);
});

test("credential encryption round-trips and fingerprints are organization scoped", () => {
  const credential = { kind: "ACCESS_CODE", accessCode: "sample-access-code" } as const;
  const encrypted = encryptCardCredential(credential, encryptionKey, fingerprintKey, "org-a");
  assert.deepEqual(decryptCardCredential(encrypted.ciphertextHex, encrypted.ivHex, encryptionKey), credential);
  assert.notEqual(encrypted.ciphertextHex, credential.accessCode);
  assert.notEqual(
    fingerprintCardCredential(credential, fingerprintKey, "org-a"),
    fingerprintCardCredential(credential, fingerprintKey, "org-b"),
  );
  assert.throws(() => decryptCardCredential(encrypted.ciphertextHex, encrypted.ivHex, Buffer.alloc(32, 8).toString("base64")));
});

test("credential fingerprints canonicalize OTHER field order", () => {
  const first = { kind: "OTHER", fields: { pin: "sample-pin", user: "sample-user" } } as const;
  const second = { kind: "OTHER", fields: { user: "sample-user", pin: "sample-pin" } } as const;
  assert.equal(fingerprintCardCredential(first, fingerprintKey, "org-a"), fingerprintCardCredential(second, fingerprintKey, "org-a"));
});

test("CSV import accepts supported credential formats and identifies file/existing duplicates", () => {
  const content = [
    "credential_type,access_code",
    "ACCESS_CODE,sample-one",
    "ACCESS_CODE,sample-one",
    "ACCESS_CODE,sample-two",
  ].join("\n");
  const firstFingerprint = parseCardCsv(content, fingerprintKey, "org-a")[0].fingerprint;
  assert.ok(firstFingerprint);
  const result = parseCardCsv(content, fingerprintKey, "org-a", new Set([firstFingerprint]));
  assert.equal(result[0].status, "ALREADY_EXISTS");
  assert.equal(result[1].status, "DUPLICATE_IN_FILE");
  assert.equal(result[2].status, "ACCEPTED");
  assert.ok(result[0].credential);
  assert.ok(result[1].credential);
});

test("CSV validation classifies incomplete and unsupported rows without returning credentials", () => {
  const result = parseCardCsv(
    "credential_type,access_code\nACCESS_CODE,\nNOT_A_KIND,hidden-value",
    fingerprintKey,
    "org-a",
  );
  assert.equal(result[0].status, "INCOMPLETE");
  assert.equal(result[1].status, "REJECTED");
  assert.equal(result[1].credential, null);
});

test("malformed CSV errors do not contain submitted credential values", () => {
  assert.throws(() => parseCardCsv("credential_type,access_code\nACCESS_CODE,\"secret", fingerprintKey, "org-a"), (error: unknown) => {
    assert.equal(error instanceof Error ? error.message : "", "INVALID_CSV");
    assert.equal(error instanceof Error ? error.message.includes("secret") : false, false);
    return true;
  });
});

test("owner transfer and agent sale select eligible cards in FIFO order", () => {
  const cards = [
    { id: "later", createdAt: "2026-01-02T00:00:00Z", possession: "OWNER_STOCK", operationState: "COMPLETED", productId: "p1", agentId: null },
    { id: "reserved", createdAt: "2026-01-01T00:00:00Z", possession: "OWNER_STOCK", operationState: "RESERVED", productId: "p1", agentId: null },
    { id: "earlier", createdAt: "2026-01-01T00:00:00Z", possession: "OWNER_STOCK", operationState: "COMPLETED", productId: "p1", agentId: null },
  ] as const;
  assert.deepEqual(selectOwnerStockForTransfer(cards, "p1", 1).map((card) => card.id), ["earlier"]);
  assert.deepEqual(selectOwnerStockForTransfer(cards, "p1", 3), []);

  const agentCards = [
    { ...cards[0], id: "wrong-agent", possession: "AGENT_STOCK", agentId: "agent-b" },
    { ...cards[0], id: "agent-card", possession: "AGENT_STOCK", agentId: "agent-a" },
  ] as const;
  assert.deepEqual(selectAgentStockForSale(agentCards, "agent-a", "p1").map((card) => card.id), ["agent-card"]);
});

test("possession and operation state transitions protect completed work", () => {
  assert.equal(canTransitionPossession("OWNER_STOCK", "AGENT_STOCK"), true);
  assert.equal(canTransitionPossession("CUSTOMER_CUSTODY", "AGENT_STOCK"), false);
  assert.equal(canTransitionOperation("RESERVED", "COMPLETED"), true);
  assert.equal(canTransitionOperation("COMPLETED", "CANCELLED"), false);
  assert.equal(canReverseWrongDelivery(false), true);
  assert.equal(canReverseWrongDelivery(true), false);
});

test("SQL contract revokes direct writes and constrains import secrets to accepted rows", () => {
  assert.match(coreSql, /alter table public\.cards enable row level security/i);
  assert.match(coreSql, /revoke all on all tables in schema public from anon, authenticated/i);
  assert.match(coreSql, /grant select \(id, organization_id, network_id, product_id, batch_id, possession,[\s\S]*?on public\.cards to authenticated/i);
  assert.doesNotMatch(coreSql, /grant select[\s\S]{0,240}credential_ciphertext[\s\S]{0,80}on public\.cards/i);
  assert.match(coreSql, /status <> 'ACCEPTED' and credential_type is null and credential_ciphertext is null and credential_iv is null and credential_fingerprint is null/i);
  assert.doesNotMatch(coreSql, /create policy [^;]+ for (insert|update|delete|all)\b/i);
});

test("every declared table enables RLS and every SECURITY DEFINER pins search_path", () => {
  const declaredTables = new Set([...coreSql, ...operationsSql].join("\n").matchAll(/create table public\.([a-z_]+)/gi).map((match) => match[1].toLowerCase()));
  const securedTables = new Set([...coreSql, ...operationsSql].join("\n").matchAll(/alter table public\.([a-z_]+) enable row level security/gi).map((match) => match[1].toLowerCase()));
  assert.deepEqual([...declaredTables].sort(), [...securedTables].sort());
  const functionSql = `${coreSql}\n${operationsSql}`;
  const definerCount = [...functionSql.matchAll(/security definer/gi)].length;
  const pinnedDefinerCount = [...functionSql.matchAll(/security definer\s+set search_path\s*=\s*''/gi)].length;
  assert.equal(definerCount, pinnedDefinerCount);
});

test("SQL contract scopes agent access to active memberships and organizations", () => {
  assert.match(coreSql, /private\.has_org_role\(cards\.organization_id, array\['AGENT'\]::text\[\]\)/i);
  assert.match(coreSql, /a\.active[\s\S]{0,100}private\.has_org_role\(transfers\.organization_id, array\['AGENT'\]/i);
  assert.match(coreSql, /actor_user_id = \(select auth\.uid\(\)\)[\s\S]{0,140}private\.has_org_role\(organization_id, array\['OWNER','ADMIN','AGENT','CUSTOMER'\]/i);
  assert.match(operationsSql, /a\.active\s+and private\.has_org_role\(p_organization_id, array\['AGENT'\]::text\[\]\)/i);
});

test("SQL contract serializes sales and replays idempotent results", () => {
  assert.match(coreSql, /unique \(organization_id, actor_user_id, operation_type, idempotency_key\)/i);
  assert.match(operationsSql, /for update skip locked/i);
  assert.match(operationsSql, /if existing_fingerprint is distinct from p_request_fingerprint[\s\S]{0,130}IDEMPOTENCY_KEY_REUSED/i);
  assert.match(operationsSql, /select c\.id into card_id[\s\S]{0,440}for update skip locked/i);
  assert.match(operationsSql, /insert into public\.deliveries[\s\S]{0,260}update public\.cards[\s\S]{0,260}insert into public\.inventory_movements/i);
  assert.match(operationsSql, /credentials_exposed[\s\S]{0,240}COMPROMISED/i);
});

test("unverifiable import fingerprints and encrypted reveal RPCs are not callable by app roles", () => {
  assert.match(operationsSql, /revoke all on function public\.create_card_batch\([\s\S]{0,150}from public, anon, authenticated/i);
  assert.match(operationsSql, /revoke all on function public\.get_card_credential\([\s\S]{0,80}from authenticated/i);
  assert.doesNotMatch(operationsSql, /grant execute on function public\.create_card_batch\([^;]+to authenticated/i);
  assert.doesNotMatch(operationsSql, /grant execute on function public\.get_card_credential\([^;]+to authenticated/i);
});

test("client security-event RPC cannot fabricate password-change or session-revocation events", () => {
  assert.match(operationsSql, /p_event_type is distinct from 'LOGIN_SUCCESS'/i);
});

test("Customer, Agent, and Admin cannot assign Owner; only bootstrap can provision it", () => {
  assert.equal(canGrantMembershipRole("AGENT", "OWNER"), false);
  assert.equal(canGrantMembershipRole("ADMIN", "OWNER"), false);
  assert.equal(canGrantMembershipRole("OWNER", "OWNER"), false);
  assert.match(operationsSql, /bootstrap_requires_service_role/i);
  assert.match(operationsSql, /not exists \(select 1 from public\.memberships m[\s\S]{0,120}role in \('OWNER','ADMIN'\)/i);
  assert.match(operationsSql, /pg_advisory_xact_lock\(1189944387, 1\)/i);
  assert.match(operationsSql, /revoke all on function public\.bootstrap_first_owner\(text, uuid\) from public, anon, authenticated/i);
  assert.match(operationsSql, /grant execute on function public\.bootstrap_first_owner\(text, uuid\) to service_role/i);
});

test("fingerprint duplicate scope is organization-local and DB-enforced", () => {
  const credential = { kind: "ACCESS_CODE", accessCode: "same-credential" } as const;
  const orgA = fingerprintCardCredential(credential, fingerprintKey, "org-a");
  const orgADuplicate = fingerprintCardCredential(credential, fingerprintKey, "org-a");
  const orgB = fingerprintCardCredential(credential, fingerprintKey, "org-b");
  assert.equal(orgA, orgADuplicate);
  assert.notEqual(orgA, orgB);
  assert.match(coreSql, /unique \(organization_id, credential_fingerprint\)/i);
  assert.doesNotMatch(coreSql, /unique\s*\(\s*credential_fingerprint\s*\)/i);
  assert.match(operationsSql, /partition by r\.credential_fingerprint/i);
});

test("transfer can be accepted only before its 24-hour expiry", () => {
  const expiresAt = "2026-10-05T00:00:00.000Z";
  assert.equal(canAcceptTransfer("PENDING_ACCEPTANCE", expiresAt, new Date("2026-10-04T23:59:59Z")), true);
  assert.equal(canAcceptTransfer("PENDING_ACCEPTANCE", expiresAt, new Date(expiresAt)), false);
  assert.equal(canAcceptTransfer("EXPIRED", expiresAt, new Date("2026-10-04T12:00:00Z")), false);
  assert.match(coreSql, /expires_at timestamptz not null default \(clock_timestamp\(\) \+ interval '24 hours'\)/i);
  assert.match(coreSql, /transfers_expiry_idx[\s\S]{0,100}where status = 'PENDING_ACCEPTANCE'/i);
  assert.match(operationsSql, /transfer\.expires_at <= clock_timestamp\(\)/i);
});

test("expired transfer releases all reserved cards to owner stock and repeated expiry is a no-op", () => {
  const card = { possession: "OWNER_STOCK", operationState: "RESERVED" } as const;
  const expiry = new Date("2026-10-05T00:00:00Z");
  const expired = expireTransferState("PENDING_ACCEPTANCE", expiry.toISOString(), [card, card], expiry);
  assert.deepEqual(expired, { status: "EXPIRED", cards: [
    { possession: "OWNER_STOCK", operationState: "COMPLETED" },
    { possession: "OWNER_STOCK", operationState: "COMPLETED" },
  ] });
  assert.equal(expireTransferState("EXPIRED", expiry.toISOString(), [card], expiry), null);
  assert.match(operationsSql, /operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state\)[\s\S]{0,260}'TRANSFER_EXPIRY'/i);
  assert.match(operationsSql, /update public\.transfers set status = 'EXPIRED' where id = transfer\.id and status = 'PENDING_ACCEPTANCE'/i);
});

test("accepted transfer cannot expire and expiry is exposed only to authenticated owner/admin", () => {
  assert.equal(expireTransferState("ACCEPTED", "2026-01-01T00:00:00Z", [
    { possession: "AGENT_STOCK", operationState: "COMPLETED" },
  ], new Date("2026-01-02T00:00:00Z")), null);
  assert.match(operationsSql, /private\.has_org_role\(p_organization_id, array\['OWNER','ADMIN'\]::text\[\]\)[\s\S]{0,100}p_limit not between 1 and 100/i);
  assert.match(operationsSql, /grant execute on function public\.expire_owner_agent_transfers\(uuid, integer, uuid\) to authenticated/i);
});

test("reversal never returns a revealed credential to saleable stock", () => {
  assert.equal(canReverseWrongDelivery(true), false);
  assert.match(operationsSql, /destination := case when exposed then 'COMPROMISED' else 'AGENT_STOCK' end/i);
  assert.match(operationsSql, /CREDENTIAL_PREVIOUSLY_REVEALED/i);
});

test("import secrets and HMAC are computed only in server-only modules; client RPC is blocked", () => {
  const actionSql = readFileSync(join(process.cwd(), "src/app/actions/imports.ts"), "utf8");
  const csvModule = readFileSync(join(process.cwd(), "src/lib/imports/csv.ts"), "utf8");
  const securityModule = readFileSync(join(process.cwd(), "src/lib/security/card-credentials.ts"), "utf8");
  const adminModule = readFileSync(join(process.cwd(), "src/lib/supabase/admin.ts"), "utf8");
  assert.match(csvModule, /^import "server-only";/);
  assert.match(securityModule, /^import "server-only";/);
  assert.match(actionSql, /parseCardCsv\(csv, fingerprintKey, organizationId\)/);
  assert.match(actionSql, /encryptCardCredential\(row\.credential, encryptionKey, fingerprintKey, organizationId\)/);
  assert.match(actionSql, /admin\.rpc\("create_card_batch"/);
  assert.match(adminModule, /^import "server-only";/);
  assert.match(operationsSql, /revoke all on function public\.create_card_batch\(uuid, uuid, uuid, text, jsonb, uuid, uuid\) from public, anon, authenticated/i);
  assert.match(operationsSql, /grant execute on function public\.create_card_batch\(uuid, uuid, uuid, text, jsonb, uuid, uuid\) to service_role/i);
});
