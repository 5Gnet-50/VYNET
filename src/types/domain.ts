/** Shared domain types. Secret card credentials are intentionally not part of Card. */

export type EntityId = string;
export type IsoDateTime = string;

export type Organization = { id: EntityId; name: string; createdAt: IsoDateTime; updatedAt: IsoDateTime };
export type User = { id: EntityId; displayName: string; phone: string; createdAt: IsoDateTime };
export type MembershipRole = "OWNER" | "ADMIN" | "AGENT" | "CUSTOMER";
export type Membership = { id: EntityId; organizationId: EntityId; userId: EntityId; role: MembershipRole; createdAt: IsoDateTime };
export type Agent = { id: EntityId; organizationId: EntityId; userId: EntityId; active: boolean; createdAt: IsoDateTime };
export type CustomerStatus = "INACTIVE" | "ACTIVE" | "SUSPENDED";
export type Customer = {
  id: EntityId; userId: EntityId; organizationId: EntityId | null; status: CustomerStatus;
  activationAgentId: EntityId | null; preferredAgentId: EntityId | null; createdAt: IsoDateTime;
};
export type Network = { id: EntityId; organizationId: EntityId; name: string; code: string; status: "ACTIVE" | "INACTIVE" };
export type Product = {
  id: EntityId; organizationId: EntityId; networkId: EntityId; name: string; code: string;
  value: number | null; price: number | null; status: "ACTIVE" | "INACTIVE";
};

/** Only for short-lived authorized reveal flows. Never log or serialize to list responses. */
export type CardCredential =
  | { kind: "ACCESS_CODE"; accessCode: string }
  | { kind: "USERNAME_PASSWORD"; username: string; password: string }
  | { kind: "VOUCHER_CODE"; voucherCode: string }
  | { kind: "PIN"; pin: string }
  | { kind: "OTHER"; fields: Readonly<Record<string, string>> };
export type CardCredentialKind = CardCredential["kind"];

export type CardPossession =
  | "QUARANTINE" | "OWNER_STOCK" | "AGENT_STOCK" | "CUSTOMER_CUSTODY"
  | "DISPUTED_LOST" | "RETIRED" | "COMPROMISED" | "VOIDED";
export type OperationState = "CREATED" | "RESERVED" | "PENDING" | "COMPLETED" | "CANCELLED" | "FAILED" | "EXPIRED";
export type ExternalNetworkState = "UNKNOWN" | "VALID" | "USED" | "EXPIRED" | "CANCELLED" | "INVALID";
export type Card = {
  id: EntityId; organizationId: EntityId; networkId: EntityId; productId: EntityId; batchId: EntityId;
  credentialType: CardCredentialKind; possession: CardPossession; operationState: OperationState;
  externalNetworkState: ExternalNetworkState; currentAgentId: EntityId | null;
  customerId: EntityId | null; createdAt: IsoDateTime; updatedAt: IsoDateTime;
};

export type CardBatchStatus = "REVIEW" | "APPROVED" | "CANCELLED";
export type CardBatch = {
  id: EntityId; organizationId: EntityId; networkId: EntityId; productId: EntityId;
  sourceFilename: string; uploadedByUserId: EntityId; uploadedAt: IsoDateTime; status: CardBatchStatus;
  totalRows: number; acceptedRows: number; rejectedRows: number; reviewRows: number;
  approvedByUserId: EntityId | null; approvedAt: IsoDateTime | null;
};
export type ImportRowStatus = "ACCEPTED" | "NEEDS_REVIEW" | "REJECTED" | "DUPLICATE_IN_FILE" | "ALREADY_EXISTS" | "INCOMPLETE";
export type ImportRow = { id: EntityId; batchId: EntityId; rowNumber: number; status: ImportRowStatus; errorCode: string | null };

export type TransferStatus = "CREATED" | "PENDING_ACCEPTANCE" | "ACCEPTED" | "CANCELLED" | "FAILED" | "EXPIRED";
export type Transfer = {
  id: EntityId; organizationId: EntityId; agentId: EntityId; networkId: EntityId; productId: EntityId;
  status: TransferStatus; createdByUserId: EntityId; acceptedByUserId: EntityId | null;
  createdAt: IsoDateTime; acceptedAt: IsoDateTime | null; expiresAt: IsoDateTime;
};
export type TransferItem = { id: EntityId; transferId: EntityId; cardId: EntityId; createdAt: IsoDateTime };
export type Sale = {
  id: EntityId; organizationId: EntityId; agentId: EntityId; customerId: EntityId; status: OperationState;
  createdByUserId: EntityId; price: number | null; currency: string | null;
  paymentMethod: string | null; settlementStatus: string | null; discount: number | null; createdAt: IsoDateTime;
};
export type SaleItem = { id: EntityId; saleId: EntityId; cardId: EntityId; createdAt: IsoDateTime };
export type Delivery = {
  id: EntityId; saleId: EntityId; customerId: EntityId; sellingAgentId: EntityId;
  state: OperationState; deliveredAt: IsoDateTime | null; createdAt: IsoDateTime;
};
export type InventoryMovement = {
  id: EntityId; organizationId: EntityId; cardId: EntityId; from: CardPossession | null;
  to: CardPossession; operationType: string; operationId: EntityId | null;
  actorUserId: EntityId; occurredAt: IsoDateTime; reasonCode: string | null;
  fromOperationState: OperationState | null; toOperationState: OperationState | null;
};
export type AuditEvent = {
  id: EntityId; organizationId: EntityId; actorUserId: EntityId | null; action: string;
  targetType: string; targetId: EntityId | null; operationId: EntityId | null; traceId: string;
  result: "SUCCESS" | "FAILURE" | "PENDING" | "UNKNOWN"; reasonCode: string | null; occurredAt: IsoDateTime;
};
export type SecurityEvent = {
  id: EntityId; organizationId: EntityId | null; actorUserId: EntityId | null; eventType: string;
  targetId: EntityId | null; result: AuditEvent["result"]; traceId: string; occurredAt: IsoDateTime;
};
export type IdempotencyKey = {
  id: EntityId; organizationId: EntityId; actorUserId: EntityId; operationType: string;
  key: string; operationId: EntityId | null; createdAt: IsoDateTime;
};
export type ClaimToken = { id: EntityId; customerId: EntityId; expiresAt: IsoDateTime; usedAt: IsoDateTime | null };
export type Device = { id: EntityId; userId: EntityId; label: string | null; revokedAt: IsoDateTime | null };
export type Session = { id: EntityId; userId: EntityId; deviceId: EntityId | null; lastSeenAt: IsoDateTime; revokedAt: IsoDateTime | null };
export type NotificationOutboxItem = {
  id: EntityId; organizationId: EntityId | null; recipientUserId: EntityId; channel: "EMAIL" | "SMS" | "PUSH";
  templateKey: string; status: "PENDING" | "PROCESSING" | "SENT" | "FAILED" | "CANCELLED"; attempts: number;
};
