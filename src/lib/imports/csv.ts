import "server-only";
import { parse } from "csv-parse/sync";
import { fingerprintCardCredential } from "../security/card-credentials";
import type { CardCredential, CardCredentialKind } from "../../types/domain";

export type ImportRowStatus =
  | "ACCEPTED"
  | "NEEDS_REVIEW"
  | "REJECTED"
  | "DUPLICATE_IN_FILE"
  | "ALREADY_EXISTS"
  | "INCOMPLETE";

export type ParsedImportRow = {
  rowNumber: number;
  status: ImportRowStatus;
  reasonCode: string | null;
  credential: CardCredential | null;
  fingerprint: string | null;
};

const allowedHeaders = new Set([
  "credential_type", "access_code", "username", "password", "voucher_code", "pin", "other_fields_json",
]);
const requiredHeaderByType: Record<CardCredentialKind, string[]> = {
  ACCESS_CODE: ["access_code"],
  USERNAME_PASSWORD: ["username", "password"],
  VOUCHER_CODE: ["voucher_code"],
  PIN: ["pin"],
  OTHER: ["other_fields_json"],
};

function hasValue(value: string | undefined): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function parseCredential(record: Record<string, string>, headers: Set<string>): CardCredential | null {
  const kind = record.credential_type as CardCredentialKind;
  if (!Object.hasOwn(requiredHeaderByType, kind)) return null;
  if (requiredHeaderByType[kind].some((header) => !headers.has(header))) return null;

  if (kind === "ACCESS_CODE" && hasValue(record.access_code)) return { kind, accessCode: record.access_code.trim() };
  if (kind === "USERNAME_PASSWORD" && hasValue(record.username) && hasValue(record.password)) {
    return { kind, username: record.username.trim(), password: record.password };
  }
  if (kind === "VOUCHER_CODE" && hasValue(record.voucher_code)) return { kind, voucherCode: record.voucher_code.trim() };
  if (kind === "PIN" && hasValue(record.pin)) return { kind, pin: record.pin.trim() };
  if (kind === "OTHER" && hasValue(record.other_fields_json)) {
    try {
      const fields: unknown = JSON.parse(record.other_fields_json);
      if (fields === null || Array.isArray(fields) || typeof fields !== "object") return null;
      const entries = Object.entries(fields);
      if (entries.length === 0 || entries.some(([name, value]) => !name || typeof value !== "string" || !value.trim())) return null;
      return { kind, fields: Object.fromEntries(entries) };
    } catch {
      return null;
    }
  }
  return null;
}

export function parseCardCsv(
  content: string,
  fingerprintKey: string | undefined,
  organizationId: string,
  existingFingerprints: ReadonlySet<string> = new Set(),
): ParsedImportRow[] {
  if (content.length > 5_000_000 || !fingerprintKey || !organizationId) {
    throw new Error("INVALID_IMPORT_INPUT");
  }

  let rows: string[][];
  try {
    rows = parse(content, {
      bom: true,
      skip_empty_lines: true,
      max_record_size: 16_384,
      relax_column_count: false,
      trim: false,
    }) as string[][];
  } catch {
    throw new Error("INVALID_CSV");
  }

  if (rows.length === 0) throw new Error("INVALID_CSV_HEADERS");
  const rawHeaders = rows[0];
  const headers = rawHeaders.map((header) => header.trim().toLowerCase());
  const headerSet = new Set(headers);
  if (headerSet.size !== headers.length || !headerSet.has("credential_type") || headers.some((header) => !allowedHeaders.has(header))) {
    throw new Error("INVALID_CSV_HEADERS");
  }
  const records = rows.slice(1);
  if (records.length > 5_000) throw new Error("IMPORT_ROW_LIMIT");

  const seen = new Set<string>();
  return records.map((row, index) => {
    const record = Object.fromEntries(headers.map((header, column) => [header, row[column] ?? ""]));
    const rowNumber = index + 2;
    const rawKind = record.credential_type?.trim().toUpperCase();
    if (!rawKind || !Object.hasOwn(requiredHeaderByType, rawKind)) {
      return { rowNumber, status: "REJECTED", reasonCode: "UNSUPPORTED_CREDENTIAL_TYPE", credential: null, fingerprint: null };
    }

    const credential = parseCredential({ ...record, credential_type: rawKind }, headerSet);
    if (!credential) {
      const requiredHeaders = requiredHeaderByType[rawKind as CardCredentialKind];
      const status = requiredHeaders.some((header) => !headerSet.has(header)) ? "NEEDS_REVIEW" : "INCOMPLETE";
      return { rowNumber, status, reasonCode: status === "NEEDS_REVIEW" ? "MISSING_REQUIRED_COLUMN" : "MISSING_CREDENTIAL_VALUE", credential: null, fingerprint: null };
    }

    const hash = fingerprintCardCredential(credential, fingerprintKey, organizationId);
    if (seen.has(hash)) {
      // Keep valid credentials in this server-only result so encrypted upload can let the DB classify duplicates.
      return { rowNumber, status: "DUPLICATE_IN_FILE", reasonCode: "DUPLICATE_IN_FILE", credential, fingerprint: hash };
    }
    seen.add(hash);
    if (existingFingerprints.has(hash)) {
      return { rowNumber, status: "ALREADY_EXISTS", reasonCode: "ALREADY_EXISTS", credential, fingerprint: hash };
    }
    return { rowNumber, status: "ACCEPTED", reasonCode: null, credential, fingerprint: hash };
  });
}
