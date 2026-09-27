import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import SleepTrialSettings from "@/components/SleepTrialSettings";

export default async function SleepTrialSettingsPage() {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  // Every role may view the permissions grid; editing is gated inside
  // SleepTrialSettings (and enforced again by set_role_permission).
  return <SleepTrialSettings />;
}
