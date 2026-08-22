import { createClient as createAdminClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function POST(request: NextRequest) {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Not authenticated" }, { status: 401 });
  }

  const body = await request.json();
  const {
    first_name,
    last_name,
    email,
    password,
    role,
    home_store_id,
    birthday,
    hire_date,
    is_active,
  } = body;

  if (
    !first_name?.trim() ||
    !last_name?.trim() ||
    !email?.trim() ||
    !password ||
    !role ||
    !home_store_id
  ) {
    return NextResponse.json(
      { error: "All fields are required" },
      { status: 400 }
    );
  }

  const admin = createAdminClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    }
  );

  const { data: caller } = await admin
    .from("employees")
    .select("role, home_store_id, stores!inner(company_id)")
    .eq("auth_user_id", user.id)
    .single();

  if (!caller || (caller.role !== "owner" && caller.role !== "admin")) {
    return NextResponse.json(
      { error: "Only owner or admin can create employees" },
      { status: 403 }
    );
  }

  const { data: targetStore } = await admin
    .from("stores")
    .select("company_id")
    .eq("id", home_store_id)
    .single();

  if (!targetStore) {
    return NextResponse.json({ error: "Store not found" }, { status: 404 });
  }

  const { data: callerStore } = await admin
    .from("stores")
    .select("company_id")
    .eq("id", caller.home_store_id)
    .single();

  if (!callerStore || callerStore.company_id !== targetStore.company_id) {
    return NextResponse.json(
      { error: "Store must be in your company" },
      { status: 403 }
    );
  }

  let authUserId: string | null = null;

  try {
    const { data: authData, error: createError } =
      await admin.auth.admin.createUser({
        email: email.trim(),
        password,
        email_confirm: true,
      });

    if (createError) {
      return NextResponse.json({ error: createError.message }, { status: 400 });
    }

    if (!authData?.user) {
      return NextResponse.json(
        { error: "Auth user creation failed" },
        { status: 500 }
      );
    }

    authUserId = authData.user.id;

    const { data: newEmployee, error: insertError } = await admin
      .from("employees")
      .insert({
        auth_user_id: authUserId,
        first_name: first_name.trim(),
        last_name: last_name.trim(),
        role,
        home_store_id,
        birthday: birthday ?? null,
        hire_date: hire_date ?? null,
        is_active: is_active ?? true,
      })
      .select()
      .single();

    if (insertError) {
      throw new Error(insertError.message);
    }

    return NextResponse.json({ employee: newEmployee }, { status: 201 });
  } catch (err: any) {
    if (authUserId) {
      await admin.auth.admin.deleteUser(authUserId);
    }

    return NextResponse.json(
      { error: err.message ?? "Failed to create employee" },
      { status: 500 }
    );
  }
}
