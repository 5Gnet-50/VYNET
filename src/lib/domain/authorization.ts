import type { MembershipRole } from "../../types/domain";

export type VynetExperience = "OWNER_ADMIN" | "AGENT" | "UNAUTHORIZED" | "AMBIGUOUS";

/** VYNET has owner/admin and agent experiences; customers belong to the separate VY CARD app. */
export function resolveVynetExperience(roles: readonly MembershipRole[]): VynetExperience {
  const ownerAdmin = roles.some((role) => role === "OWNER" || role === "ADMIN");
  const agent = roles.includes("AGENT");
  if (ownerAdmin && agent) return "AMBIGUOUS";
  if (ownerAdmin) return "OWNER_ADMIN";
  if (agent) return "AGENT";
  return "UNAUTHORIZED";
}

/** Owner membership is provisioned only by the one-time administrative bootstrap. */
export function canGrantMembershipRole(actorRole: MembershipRole, targetRole: MembershipRole): boolean {
  if (targetRole === "OWNER") return false;
  if (actorRole === "OWNER") return true;
  if (actorRole === "ADMIN") return targetRole === "ADMIN" || targetRole === "AGENT";
  return false;
}
