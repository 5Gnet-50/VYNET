import { redirect } from "next/navigation";
import { getCurrentVynetExperience } from "@/lib/auth/experience";

export default async function DashboardPage() {
  const experience = await getCurrentVynetExperience();
  if (experience === "OWNER_ADMIN") redirect("/admin");
  if (experience === "AGENT") redirect("/agent");
  redirect("/login");
}
