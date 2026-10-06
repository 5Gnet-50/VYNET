import type { TransferStatus } from "../../types/domain";

export type TransferCardState = { possession: "OWNER_STOCK" | "AGENT_STOCK"; operationState: "RESERVED" | "COMPLETED" };

export type TransferRequestLineInput = { productId: string; quantity: number };
export type ApprovedTransferLineInput = { productId: string; approvedQuantity: number };

/** Validate the multi-category request shape before it reaches an authorized server operation. */
export function validateTransferRequestLines(lines: readonly TransferRequestLineInput[]): boolean {
  return lines.length > 0
    && lines.every((line) => line.productId.length > 0 && line.productId === line.productId.trim()
      && Number.isSafeInteger(line.quantity) && line.quantity > 0)
    && new Set(lines.map((line) => line.productId.trim())).size === lines.length;
}

/** Owner decisions must account for every requested product and cannot inflate requested quantities. */
export function validateApprovedTransferLines(
  requested: readonly TransferRequestLineInput[],
  approved: readonly ApprovedTransferLineInput[],
): boolean {
  if (!validateTransferRequestLines(requested) || approved.length !== requested.length) return false;
  const requestedByProduct = new Map(requested.map((line) => [line.productId, line.quantity]));
  if (new Set(approved.map((line) => line.productId)).size !== approved.length) return false;
  return approved.some((line) => line.approvedQuantity > 0) && approved.every((line) => {
    const requestedQuantity = requestedByProduct.get(line.productId);
    return requestedQuantity !== undefined && Number.isSafeInteger(line.approvedQuantity)
      && line.approvedQuantity >= 0 && line.approvedQuantity <= requestedQuantity;
  });
}

export function canAcceptTransfer(status: TransferStatus, expiresAt: string, now: Date): boolean {
  const expiration = Date.parse(expiresAt);
  return status === "PENDING_ACCEPTANCE" && Number.isFinite(expiration) && now.getTime() < expiration;
}

export function expireTransferState(
  status: TransferStatus,
  expiresAt: string,
  cards: readonly TransferCardState[],
  now: Date,
): { status: "EXPIRED"; cards: TransferCardState[] } | null {
  const expiration = Date.parse(expiresAt);
  if (status !== "PENDING_ACCEPTANCE" || !Number.isFinite(expiration) || now.getTime() < expiration
    || cards.length === 0 || cards.some((card) => card.possession !== "OWNER_STOCK" || card.operationState !== "RESERVED")) {
    return null;
  }
  return { status: "EXPIRED", cards: cards.map(() => ({ possession: "OWNER_STOCK", operationState: "COMPLETED" })) };
}
