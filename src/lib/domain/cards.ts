import type { CardPossession, OperationState } from "../../types/domain";

export type StockCard = {
  id: string;
  createdAt: string;
  possession: CardPossession;
  operationState: OperationState;
  productId: string;
  agentId?: string | null;
};

const allowedTransitions: Record<CardPossession, readonly CardPossession[]> = {
  QUARANTINE: ["OWNER_STOCK", "DISPUTED_LOST", "RETIRED"],
  OWNER_STOCK: ["AGENT_STOCK", "DISPUTED_LOST", "RETIRED"],
  AGENT_STOCK: ["CUSTOMER_CUSTODY", "DISPUTED_LOST", "RETIRED"],
  CUSTOMER_CUSTODY: ["DISPUTED_LOST", "RETIRED", "COMPROMISED", "VOIDED"],
  DISPUTED_LOST: ["OWNER_STOCK", "AGENT_STOCK", "CUSTOMER_CUSTODY", "RETIRED", "COMPROMISED", "VOIDED"],
  RETIRED: ["VOIDED"],
  COMPROMISED: ["VOIDED", "RETIRED"],
  VOIDED: ["RETIRED"],
};

const allowedOperationTransitions: Record<OperationState, readonly OperationState[]> = {
  CREATED: ["RESERVED", "PENDING", "CANCELLED", "FAILED", "EXPIRED"],
  RESERVED: ["PENDING", "COMPLETED", "CANCELLED", "FAILED", "EXPIRED"],
  PENDING: ["COMPLETED", "CANCELLED", "FAILED", "EXPIRED"],
  COMPLETED: [],
  CANCELLED: [],
  FAILED: [],
  EXPIRED: [],
};

export function canTransitionPossession(from: CardPossession, to: CardPossession): boolean {
  return allowedTransitions[from].includes(to);
}

export function canTransitionOperation(from: OperationState, to: OperationState): boolean {
  return allowedOperationTransitions[from].includes(to);
}

export function canReverseWrongDelivery(credentialsExposed: boolean): boolean {
  return !credentialsExposed;
}

export function selectFifoCards<T extends { id: string; createdAt: string }>(
  cards: readonly T[],
  quantity: number,
): T[] {
  if (!Number.isSafeInteger(quantity) || quantity < 1 || cards.length < quantity) {
    return [];
  }

  return [...cards]
    .sort((left, right) => left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id))
    .slice(0, quantity);
}

export function selectOwnerStockForTransfer(
  cards: readonly StockCard[],
  productId: string,
  quantity: number,
): StockCard[] {
  const eligible = cards.filter(
    (card) => card.possession === "OWNER_STOCK" && card.operationState === "COMPLETED" && card.productId === productId,
  );
  return selectFifoCards(eligible, quantity);
}

export function selectAgentStockForSale(
  cards: readonly StockCard[],
  agentId: string,
  productId: string,
  quantity = 1,
): StockCard[] {
  const eligible = cards.filter(
    (card) => card.possession === "AGENT_STOCK" && card.operationState === "COMPLETED"
      && card.agentId === agentId && card.productId === productId,
  );
  return selectFifoCards(eligible, quantity);
}
