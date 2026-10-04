import type { EntityId } from "@/types/domain";

/** Contract only. No in-memory or mock implementation is configured. */
export interface ReadRepository<TEntity> {
  findById(id: EntityId): Promise<TEntity | null>;
}

/** Backend-specific repositories will be implemented server-side in a later phase. */
