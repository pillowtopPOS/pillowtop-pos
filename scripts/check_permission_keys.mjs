// Drift check: every permission key accepted by the LATEST
// is_valid_permission_key migration must appear in ALL_PERMISSIONS
// (lib/sleepTrial/permissions.ts), and vice versa.
// Run: node scripts/check_permission_keys.mjs
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const migDir = "supabase/migrations";
// Latest migration that defines is_valid_permission_key wins.
const files = readdirSync(migDir)
  .filter((f) => f.endsWith(".sql"))
  .sort();
let latest = null;
for (const f of files) {
  const sql = readFileSync(join(migDir, f), "utf8");
  if (/create or replace function public\.is_valid_permission_key/.test(sql)) {
    latest = { f, sql };
  }
}
if (!latest) {
  console.log("FAIL: no migration defines is_valid_permission_key");
  process.exit(1);
}

// Extract the function body (up to the closing $$;) and pull 'a.b' keys.
const start = latest.sql.search(
  /create or replace function public\.is_valid_permission_key/
);
const end = latest.sql.indexOf("$$;", start);
const body = latest.sql.slice(start, end === -1 ? undefined : end);
const dbKeys = new Set(
  [...body.matchAll(/'([a-z_]+\.[a-z_]+)'/g)].map((m) => m[1])
);

const ts = readFileSync("lib/sleepTrial/permissions.ts", "utf8");
const uiKeys = new Set(
  [...ts.matchAll(/key:\s*"([a-z_]+\.[a-z_]+)"/g)].map((m) => m[1])
);
// SLEEP_TRIAL_PERMISSIONS uses `key: "..."` too, so the regex covers it.

const missingInUi = [...dbKeys].filter((k) => !uiKeys.has(k)).sort();
const missingInDb = [...uiKeys].filter((k) => !dbKeys.has(k)).sort();

console.log(`Checked against ${latest.f}`);
console.log(`DB keys: ${dbKeys.size}, UI keys: ${uiKeys.size}`);
if (missingInUi.length) {
  console.log("FAIL in ALL_PERMISSIONS (accepted by DB, not shown):");
  missingInUi.forEach((k) => console.log(`  - ${k}`));
}
if (missingInDb.length) {
  console.log("FAIL in DB (shown in UI, rejected by is_valid_permission_key):");
  missingInDb.forEach((k) => console.log(`  - ${k}`));
}
if (!missingInUi.length && !missingInDb.length) {
  console.log("PASS: ALL_PERMISSIONS matches is_valid_permission_key exactly");
}
process.exit(missingInUi.length || missingInDb.length ? 1 : 0);
