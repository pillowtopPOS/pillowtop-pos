const fs = require("fs");
const { createClient } = require("@supabase/supabase-js");

function loadEnv(path = ".env.local") {
  if (!fs.existsSync(path)) {
    throw new Error(`${path} not found`);
  }
  const lines = fs.readFileSync(path, "utf8").split("\n");
  for (const line of lines) {
    const [k, ...rest] = line.split("=");
    if (k && !k.startsWith("#")) {
      process.env[k.trim()] = rest.join("=").trim();
    }
  }
}

loadEnv();

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !anonKey || !serviceKey) {
  throw new Error("Missing Supabase env vars");
}

const admin = createClient(url, serviceKey, {
  auth: { persistSession: false },
});

async function sleepJourneysFor(client) {
  const { data, error } = await client
    .from("sleep_journeys")
    .select("id, store_id, product_summary")
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data ?? [];
}

async function run() {
  // Check the migration has been applied
  const { error: companiesCheck } = await admin
    .from("companies")
    .select("id", { head: true });
  if (companiesCheck) {
    console.error("Migration not applied yet:", companiesCheck.message);
    console.error("Run supabase/migrations/003_multi_company.sql first.");
    process.exit(1);
  }

  const ts = Date.now();
  let created = {};

  try {
    // Two companies, one store each
    const { data: c1 } = await admin
      .from("companies")
      .insert({ name: `Test Co A ${ts}` })
      .select("id")
      .single();
    const { data: c2 } = await admin
      .from("companies")
      .insert({ name: `Test Co B ${ts}` })
      .select("id")
      .single();

    const { data: s1 } = await admin
      .from("stores")
      .insert({
        name: `Store A ${ts}`,
        company_id: c1.id,
        trial_length_nights: 120,
      })
      .select("id")
      .single();
    const { data: s2 } = await admin
      .from("stores")
      .insert({
        name: `Store B ${ts}`,
        company_id: c2.id,
        trial_length_nights: 120,
      })
      .select("id")
      .single();

    // Two auth users, one per store
    const emailA = `test-a-${ts}@example.com`;
    const emailB = `test-b-${ts}@example.com`;
    const { data: userA } = await admin.auth.admin.createUser({
      email: emailA,
      password: "Password123!",
      email_confirm: true,
      user_metadata: { active_store_id: s1.id },
    });
    const { data: userB } = await admin.auth.admin.createUser({
      email: emailB,
      password: "Password123!",
      email_confirm: true,
      user_metadata: { active_store_id: s2.id },
    });

    // Two employees
    const { data: empA } = await admin
      .from("employees")
      .insert({
        name: `Emp A ${ts}`,
        role: "sales",
        home_store_id: s1.id,
        auth_user_id: userA.user.id,
      })
      .select("id")
      .single();
    const { data: empB } = await admin
      .from("employees")
      .insert({
        name: `Emp B ${ts}`,
        role: "sales",
        home_store_id: s2.id,
        auth_user_id: userB.user.id,
      })
      .select("id")
      .single();

    // One customer + journey per company
    const { data: custA } = await admin
      .from("customers")
      .insert({
        first_name: "A",
        last_name: "Customer",
        phone: `555-0001-${ts}`,
        email: `a-${ts}@example.com`,
      })
      .select("id")
      .single();
    const { data: custB } = await admin
      .from("customers")
      .insert({
        first_name: "B",
        last_name: "Customer",
        phone: `555-0002-${ts}`,
        email: `b-${ts}@example.com`,
      })
      .select("id")
      .single();

    const { data: jA } = await admin
      .from("sleep_journeys")
      .insert({
        customer_id: custA.id,
        store_id: s1.id,
        product_summary: "Co A mattress",
      })
      .select("id")
      .single();
    const { data: jB } = await admin
      .from("sleep_journeys")
      .insert({
        customer_id: custB.id,
        store_id: s2.id,
        product_summary: "Co B mattress",
      })
      .select("id")
      .single();

    created = { c1, c2, s1, s2, userA, userB, empA, empB, custA, custB, jA, jB };

    // Test Company A employee
    const clientA = createClient(url, anonKey, {
      auth: { persistSession: false },
    });
    const { data: sessionA } = await clientA.auth.signInWithPassword({
      email: emailA,
      password: "Password123!",
    });
    if (!sessionA.session) {
      throw new Error("Failed to sign in as Company A employee");
    }

    const listA = await sleepJourneysFor(clientA);
    const canSeeOwnA =
      listA.length === 1 && listA[0].id === jA.id && listA[0].store_id === s1.id;

    const { data: listAOther } = await clientA
      .from("sleep_journeys")
      .select("id")
      .eq("store_id", s2.id);
    const cannotSeeB = (listAOther ?? []).length === 0;

    // Test Company B employee
    const clientB = createClient(url, anonKey, {
      auth: { persistSession: false },
    });
    const { data: sessionB } = await clientB.auth.signInWithPassword({
      email: emailB,
      password: "Password123!",
    });
    if (!sessionB.session) {
      throw new Error("Failed to sign in as Company B employee");
    }

    const listB = await sleepJourneysFor(clientB);
    const canSeeOwnB =
      listB.length === 1 && listB[0].id === jB.id && listB[0].store_id === s2.id;

    const { data: listBOther } = await clientB
      .from("sleep_journeys")
      .select("id")
      .eq("store_id", s1.id);
    const cannotSeeA = (listBOther ?? []).length === 0;

    console.log("Company A employee sees:", listA.length, "journey(s)", canSeeOwnA ? "✓" : "✗");
    console.log("Company A cannot see B:", cannotSeeB ? "✓" : "✗");
    console.log("Company B employee sees:", listB.length, "journey(s)", canSeeOwnB ? "✓" : "✗");
    console.log("Company B cannot see A:", cannotSeeA ? "✓" : "✗");

    if (!canSeeOwnA || !canSeeOwnB || !cannotSeeB || !cannotSeeA) {
      throw new Error("Multi-company isolation test failed");
    }

    console.log("\nPASS: Multi-company RLS boundary is working.");
  } finally {
    if (created.jA && created.jB) {
      await admin.from("sleep_journeys").delete().in("id", [created.jA.id, created.jB.id]);
    }
    if (created.custA && created.custB) {
      await admin.from("customers").delete().in("id", [created.custA.id, created.custB.id]);
    }
    if (created.empA && created.empB) {
      await admin.from("employees").delete().in("id", [created.empA.id, created.empB.id]);
    }
    if (created.s1 && created.s2) {
      await admin.from("stores").delete().in("id", [created.s1.id, created.s2.id]);
    }
    if (created.c1 && created.c2) {
      await admin.from("companies").delete().in("id", [created.c1.id, created.c2.id]);
    }
    if (created.userA && created.userB) {
      await admin.auth.admin.deleteUser(created.userA.user.id);
      await admin.auth.admin.deleteUser(created.userB.user.id);
    }
  }
}

run().catch((err) => {
  console.error("\nFAIL:", err.message);
  process.exit(1);
});
