import type { ReactNode } from "react";
import { requireVynetExperience } from "@/lib/auth/experience";

export default async function AgentLayout({ children }: { children: ReactNode }) {
  await requireVynetExperience("AGENT");
  return children;
}
