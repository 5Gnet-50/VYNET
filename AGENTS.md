<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## Project rules

- Keep all user-facing interfaces Arabic and right-to-left (RTL).
- Do not change business requirements or add features without an explicit decision.
- Never commit secrets. Never log card credentials or include them in errors, URLs, or analytics.
- Do not modify a database or Supabase configuration without an explicit request.
- Run `pnpm lint`, `pnpm typecheck`, and `pnpm build` after significant changes.
- Review security and authorization before considering a feature complete. UI visibility is not authorization.
- Future sensitive inventory and financial operations must run server-side and transactionally.
- Prevent the same card from being sold twice.
- Use idempotency for future sensitive operations that may be retried.
- Do not present placeholder pages, repository contracts, or sample UI as working services or persisted data.
- Keep the MVP as a modular monolith; do not add services or dependencies without a concrete requirement.
