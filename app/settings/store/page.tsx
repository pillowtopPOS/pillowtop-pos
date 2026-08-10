import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import StoreManagement from "@/components/StoreManagement";

export default async function StoreSettingsPage() {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { data: employee } = await supabase
    .from("employees")
    .select("role")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  if (employee?.role !== "owner" && employee?.role !== "admin") {
    redirect("/board");
  }

  return <StoreManagement />;
}
