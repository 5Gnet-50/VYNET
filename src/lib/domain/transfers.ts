import type { TransferStatus } from "../../types/domain";

export type TransferCardState = { possession: "OWNER_STOCK" | "AGENT_STOCK"; operationState: "RESERVED" | "COMPLETED" };

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
