# PillowTop POS — Project Rules

## Dev Server After Changes

- Zach tests on the running dev server at localhost:3000 and should never
  have to ask for a restart.
- For verification, use `npm run build:verify` (outputs to `.next-verify`)
  or `npm run typecheck`. **Never run `npm run build` while the dev server
  is running** — it overwrites the dev server's `.next` directory and breaks
  the running server with "Cannot find module" errors.
- After any change that affects what Zach sees or uses (frontend, config,
  env vars, packages), make sure the dev server is serving the new code
  before reporting back. Restart it yourself if needed; if you see
  "Cannot find module" errors from `.next`, stop the server, delete
  `.next`, and restart.
- Before reporting done, confirm a page loads normally and include one
  line: "Dev server restarted and verified" or "Dev server hot-reloaded,
  verified."

## Git

- Commit and push to GitHub as part of finishing any migration or frontend
  change — not just at the end of a phase. "Done" means committed and
  pushed, same as it means typecheck clean and dev server verified.
- If a push ever fails (auth, network, rejected remote), flag it to Zach
  immediately instead of continuing to work locally. Two months of work
  was once stranded locally because an expired token made pushes fail
  silently — visibility into failures is the point.

## Database

- Never run database migrations. Zach runs them in the Supabase SQL editor
  after review.

## Specifications

- Sleep Trial work follows docs/sleep-trial-engine.md. Build only the phase
  you are asked for (Section 33). If the spec conflicts with existing code
  or the canonical spec, stop and report it instead of guessing.
