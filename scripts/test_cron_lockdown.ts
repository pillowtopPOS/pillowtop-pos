// HTTP-level test for the /api/cron lockdown and /api/automation/tick.
// Spawns two `next start` servers from .next-prod (one with
// CRON_SECRET set, one without), creates throwaway fixtures in the
// dev Supabase project (a second company, an auth user + employee,
// overdue Sleep Trial journeys), runs every case, then deletes the
// fixtures. Run: npx tsx scripts/test_cron_lockdown.ts
import { spawn, type ChildProcess } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

// --- env ------------------------------------------------------------------
for (const line of readFileSync(".env.local", "utf8").split("\n")) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const URL_ENV = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const REF = new URL(URL_ENV).hostname.split(".")[0];
const admin = createClient(URL_ENV, SVC, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const anon = createClient(URL_ENV, ANON);

const PORT_SECRET = 3210;
const PORT_NOSECRET = 3211;
const CRON_SECRET = "cron-test-secret";

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures += 1;
}

// --- fixtures --------------------------------------------------------------
const tag = `crt${Date.now().toString(36)}`;
let companyB: { id: string; storeId: string } | null = null;
let journeyA: string | null = null; // company A overdue trial journey
let journeyB: string | null = null; // company B overdue trial journey
let customerA: string | null = null;
let customerB: string | null = null;
let employeeId: string | null = null;
let authUserId: string | null = null;
let mainStoreId: string | null = null;

async function setup() {
  const { data: stores } = await admin
    .from("stores")
    .select("id, company_id")
    .eq("is_active", true)
    .limit(1);
  mainStoreId = stores![0].id;
  const companyA = stores![0].company_id as string;

  // Company B fixture: company + store + customer + overdue trial journey.
  const { data: co } = await admin
    .from("companies")
    .insert({ name: `__${tag}_co__`, business_timezone: "America/Denver" })
    .select("id")
    .single();
  companyB = { id: co!.id, storeId: "" };
  const { data: st } = await admin
    .from("stores")
    .insert({
      company_id: co!.id,
      name: `__${tag}_store__`,
      location_type: "STORE",
      is_active: true,
    })
    .select("id")
    .single();
  companyB.storeId = st!.id;
}

async function createTickFixtures() {
  const { data: cuB } = await admin
    .from("customers")
    .insert({
      first_name: `__${tag}B`,
      last_name: "CronTest",
      phone: "5550000000",
      email: `${tag}b@cron-test.invalid`,
      street_address: "1 Test St",
      city: "Denver",
      state: "CO",
      zip_code: "80000",
    })
    .select("id")
    .single();
  customerB = cuB!.id;
  const { data: jB } = await admin
    .from("sleep_journeys")
    .insert({
      customer_id: customerB,
      store_id: companyB!.storeId,
      current_state: "Sleep Trial",
      delivered_at: "2020-01-01",
      trial_length_nights: 1,
    })
    .select("id")
    .single();
  journeyB = jB!.id;

  // Company A fixture on the real company's main store.
  const { data: cuA } = await admin
    .from("customers")
    .insert({
      first_name: `__${tag}A`,
      last_name: "CronTest",
      phone: "5550000001",
      email: `${tag}a@cron-test.invalid`,
      street_address: "1 Test St",
      city: "Denver",
      state: "CO",
      zip_code: "80000",
    })
    .select("id")
    .single();
  customerA = cuA!.id;
  const { data: jA } = await admin
    .from("sleep_journeys")
    .insert({
      customer_id: customerA,
      store_id: mainStoreId,
      current_state: "Sleep Trial",
      delivered_at: "2020-01-01",
      trial_length_nights: 1,
    })
    .select("id")
    .single();
  journeyA = jA!.id;

  // Auth user + employee in company A for the signed-in tick.
  const email = `${tag}@cron-test.invalid`;
  const { data: u, error: uErr } = await admin.auth.admin.createUser({
    email,
    password: "CronTest123!",
    email_confirm: true,
  });
  if (uErr) throw uErr;
  authUserId = u.user!.id;
  const { data: emp } = await admin
    .from("employees")
    .insert({
      first_name: "Cron",
      last_name: "Test",
      role: "employee",
      home_store_id: mainStoreId,
      auth_user_id: authUserId,
      is_active: true,
    })
    .select("id")
    .single();
  employeeId = emp!.id;
}

async function cleanup() {
  const ids = [journeyA, journeyB].filter(Boolean) as string[];
  if (ids.length) {
    await admin.from("journey_events").delete().in("journey_id", ids);
    await admin.from("sleep_journeys").delete().in("id", ids);
  }
  if (customerA) await admin.from("customers").delete().eq("id", customerA);
  if (customerB) await admin.from("customers").delete().eq("id", customerB);
  if (employeeId) await admin.from("employees").delete().eq("id", employeeId);
  if (companyB) {
    await admin.from("stores").delete().eq("id", companyB.storeId);
    await admin.from("companies").delete().eq("id", companyB.id);
  }
  if (authUserId) await admin.auth.admin.deleteUser(authUserId);
}

// --- server helpers ---------------------------------------------------------
const servers: ChildProcess[] = [];
async function startServer(port: number, withSecret: boolean) {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    NEXT_DIST_DIR: ".next-prod",
    PORT: String(port),
  };
  if (withSecret) env.CRON_SECRET = CRON_SECRET;
  else delete env.CRON_SECRET;
  const p = spawn("npx", ["next", "start", "-p", String(port)], {
    env,
    stdio: "ignore",
  });
  servers.push(p);
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://localhost:${port}/login`);
      if (r.status) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`server on ${port} did not start`);
}

async function sessionCookie(): Promise<string> {
  const { data, error } = await anon.auth.signInWithPassword({
    email: `${tag}@cron-test.invalid`,
    password: "CronTest123!",
  });
  if (error || !data.session) throw error ?? new Error("no session");
  const b64 = Buffer.from(JSON.stringify(data.session), "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `sb-${REF}-auth-token=base64-${b64}`;
}

async function hasTrialEvent(journeyId: string): Promise<boolean> {
  const { data } = await admin
    .from("journey_events")
    .select("id")
    .eq("journey_id", journeyId)
    .eq("event_type", "trial_completed")
    .limit(1);
  return (data ?? []).length > 0;
}

// --- main --------------------------------------------------------------------
async function main() {
  await setup();
  console.log(`fixtures: companyB=${companyB?.id} journeyA=${journeyA} journeyB=${journeyB}`);

  await startServer(PORT_SECRET, true);
  await startServer(PORT_NOSECRET, false);
  const base = `http://localhost:${PORT_SECRET}`;
  const noSecret = `http://localhost:${PORT_NOSECRET}`;

  // /api/cron lockdown
  let r = await fetch(`${base}/api/cron`);
  check("cron no header -> 401", r.status === 401, `got ${r.status}`);
  r = await fetch(`${base}/api/cron`, {
    headers: { authorization: "Bearer wrong-secret" },
  });
  check("cron wrong secret -> 401", r.status === 401, `got ${r.status}`);
  r = await fetch(`${base}/api/cron`, {
    headers: { authorization: `Bearer ${CRON_SECRET}é` },
  });
  check(
    "cron non-ASCII header -> 401",
    r.status === 401,
    `got ${r.status}`
  );
  r = await fetch(`${base}/api/cron`, {
    headers: { authorization: `Bearer ${CRON_SECRET}` },
  });
  check("cron right secret -> 200", r.status === 200, `got ${r.status} ${await r.text()}`);
  r = await fetch(`${noSecret}/api/cron`);
  check(
    "cron CRON_SECRET unset -> 500",
    r.status === 500 && (await r.json()).error === "Cron not configured",
    `got ${r.status}`
  );

  // Journeys are created AFTER the cron tests so the global cron run
  // cannot complete them first — the tick assertions below then prove
  // the signed-in tick (not the cron call) touched company A only.
  await createTickFixtures();
  console.log(`tick fixtures: journeyA=${journeyA} journeyB=${journeyB}`);

  // /api/automation/tick
  r = await fetch(`${base}/api/automation/tick`, { method: "POST" });
  check("tick signed out -> 401", r.status === 401, `got ${r.status}`);
  r = await fetch(`${base}/api/automation/tick`);
  check("tick GET -> 405", r.status === 405, `got ${r.status}`);

  const cookie = await sessionCookie();
  r = await fetch(`${base}/api/automation/tick`, {
    method: "POST",
    headers: { cookie },
  });
  const tickBody = await r.json().catch(() => ({}));
  check("tick signed in -> 200", r.status === 200, `got ${r.status} ${JSON.stringify(tickBody)}`);

  // Only company A's overdue trial journey got the event; company B's did not.
  const aDone = journeyA ? await hasTrialEvent(journeyA) : false;
  const bDone = journeyB ? await hasTrialEvent(journeyB) : false;
  check("tick completed company A fixture", aDone);
  check("tick left company B fixture untouched", !bDone);

  r = await fetch(`${base}/api/automation/tick`, {
    method: "POST",
    headers: { cookie },
  });
  const tick2 = await r.json().catch(() => ({}));
  check(
    "second tick within 60s -> skipped",
    r.status === 200 && tick2.skipped === true,
    `got ${r.status} ${JSON.stringify(tick2)}`
  );
}

main()
  .catch((e) => {
    failures += 1;
    console.log(`FAIL setup/run: ${e?.message ?? e}`);
  })
  .finally(async () => {
    for (const p of servers) p.kill("SIGTERM");
    await cleanup();
    console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
    process.exit(failures === 0 ? 0 : 1);
  });
