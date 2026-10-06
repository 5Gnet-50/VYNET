import "server-only";

import { redirect } from "next/navigation";
import { resolveVynetExperience, type VynetExperience } from "@/lib/domain/authorization";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function getCurrentVynetExperience(): Promise<VynetExperience> {
  const supabase = await createSupabaseServerClient();
  if (!supabase) return "UNAUTHORIZED";
  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) return "UNAUTHORIZED";

  const { data: memberships, error } = await supabase
    .from("memberships").select("role").eq("user_id", user.id);
  if (error || !memberships) return "UNAUTHORIZED";
  const experience = resolveVynetExperience(memberships.map(({ role }) => role));
  if (experience === "AGENT") {
    const { data: agents, error: agentError } = await supabase
      .from("agents").select("active").eq("user_id", user.id);
    if (agentError || !agents?.some(({ active }) => active)) return "UNAUTHORIZED";
  }
  return experience;
}

export async function requireVynetExperience(expected: "OWNER_ADMIN" | "AGENT"): Promise<void> {
  const experience = await getCurrentVynetExperience();
  if (experience !== expected) redirect(experience === "UNAUTHORIZED" ? "/login" : "/dashboard");
}
