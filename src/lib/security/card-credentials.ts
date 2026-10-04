import "server-only";
import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";
import type { CardCredential } from "../../types/domain";

export type EncryptedCardCredential = {
  ciphertextHex: string;
  ivHex: string;
  fingerprintHex: string;
  keyVersion: number;
};

function canonicalCredential(credential: CardCredential): string {
  if (credential.kind !== "OTHER") return JSON.stringify(credential);
  const fields = Object.fromEntries(Object.entries(credential.fields).sort(([a], [b]) => a.localeCompare(b)));
  return JSON.stringify({ kind: credential.kind, fields });
}

function isCardCredential(value: unknown): value is CardCredential {
  if (value === null || typeof value !== "object" || !("kind" in value)) return false;
  const record = value as Record<string, unknown>;
  switch (record.kind) {
    case "ACCESS_CODE": return typeof record.accessCode === "string";
    case "USERNAME_PASSWORD": return typeof record.username === "string" && typeof record.password === "string";
    case "VOUCHER_CODE": return typeof record.voucherCode === "string";
    case "PIN": return typeof record.pin === "string";
    case "OTHER":
      return record.fields !== null && typeof record.fields === "object" && !Array.isArray(record.fields)
        && Object.values(record.fields).every((field) => typeof field === "string");
    default: return false;
  }
}

function decodeSecretKey(encoded: string | undefined, variableName: string): Buffer {
  if (!encoded || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error(`MISSING_${variableName}`);
  const key = Buffer.from(encoded, "base64");
  if (key.length !== 32 || key.toString("base64").replace(/=+$/, "") !== encoded.replace(/=+$/, "")) {
    throw new Error(`INVALID_${variableName}`);
  }
  return key;
}

export function fingerprintCardCredential(
  credential: CardCredential,
  fingerprintKey: string | undefined,
  organizationId: string,
): string {
  const key = decodeSecretKey(fingerprintKey, "CARD_FINGERPRINT_KEY");
  return createHmac("sha256", key)
    .update(organizationId)
    .update("\0")
    .update(canonicalCredential(credential))
    .digest("hex");
}

export function encryptCardCredential(
  credential: CardCredential,
  encryptionKey: string | undefined,
  fingerprintKey: string | undefined,
  organizationId: string,
  keyVersion = 1,
): EncryptedCardCredential {
  if (!Number.isSafeInteger(keyVersion) || keyVersion < 1 || keyVersion > 32767) throw new Error("INVALID_CARD_ENCRYPTION_KEY_VERSION");
  const key = decodeSecretKey(encryptionKey, "CARD_ENCRYPTION_KEY");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([
    cipher.update(canonicalCredential(credential), "utf8"),
    cipher.final(),
    cipher.getAuthTag(),
  ]);

  return {
    ciphertextHex: ciphertext.toString("hex"),
    ivHex: iv.toString("hex"),
    fingerprintHex: fingerprintCardCredential(credential, fingerprintKey, organizationId),
    keyVersion,
  };
}

export function decryptCardCredential(
  ciphertextHex: string,
  ivHex: string,
  encryptionKey: string | undefined,
): CardCredential {
  const key = decodeSecretKey(encryptionKey, "CARD_ENCRYPTION_KEY");
  const ciphertext = Buffer.from(ciphertextHex, "hex");
  const iv = Buffer.from(ivHex, "hex");
  if (iv.length !== 12 || ciphertext.length < 17) throw new Error("INVALID_ENCRYPTED_CARD_CREDENTIAL");
  const encrypted = ciphertext.subarray(0, -16);
  const authTag = ciphertext.subarray(-16);
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(authTag);
  const plaintext = Buffer.concat([decipher.update(encrypted), decipher.final()]).toString("utf8");
  const credential: unknown = JSON.parse(plaintext);
  if (!isCardCredential(credential)) throw new Error("INVALID_ENCRYPTED_CARD_CREDENTIAL");
  return credential;
}
