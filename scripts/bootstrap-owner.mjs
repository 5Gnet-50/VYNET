import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ownerUserId = process.env.BOOTSTRAP_OWNER_USER_ID;
const organizationName = process.env.BOOTSTRAP_ORGANIZATION_NAME;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

if (!url || !serviceRoleKey || !ownerUserId || !organizationName
  || !uuidPattern.test(ownerUserId) || organizationName.trim().length < 1 || organizationName.trim().length > 160) {
  process.stderr.write("Missing or invalid bootstrap environment. No operation performed.\n");
  process.exitCode = 2;
} else {
  const supabase = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const { data, error } = await supabase.rpc("bootstrap_first_owner", {
    p_organization_name: organizationName.trim(),
    p_owner_user_id: ownerUserId,
  });
  if (error) {
    process.stderr.write("Owner bootstrap failed. Check the test environment and one-time eligibility.\n");
    process.exitCode = 1;
  } else {
    process.stdout.write(`Bootstrap completed for organization ${data}.\n`);
  }
}
