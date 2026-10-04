import type { MembershipRole } from "../../types/domain";

/** Owner membership is provisioned only by the one-time administrative bootstrap. */
export function canGrantMembershipRole(actorRole: MembershipRole, targetRole: MembershipRole): boolean {
  if (targetRole === "OWNER") return false;
  if (actorRole === "OWNER") return true;
  if (actorRole === "ADMIN") return targetRole === "ADMIN" || targetRole === "AGENT" || targetRole === "CUSTOMER";
  return false;
}
