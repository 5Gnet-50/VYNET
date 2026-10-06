import type { ReactNode } from "react";
import { requireVynetExperience } from "@/lib/auth/experience";

export default async function OwnerAdminLayout({ children }: { children: ReactNode }) {
  await requireVynetExperience("OWNER_ADMIN");
  return children;
}
