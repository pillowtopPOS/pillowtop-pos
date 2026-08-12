import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import EmployeeManagement from "@/components/EmployeeManagement";

export default async function EmployeeSettingsPage() {
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

  return <EmployeeManagement />;
}
