import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import DepositPolicyForm from "@/components/DepositPolicyForm";

export default async function DepositPolicyPage() {
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

  return <DepositPolicyForm />;
}
