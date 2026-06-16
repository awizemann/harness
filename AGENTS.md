<!-- memophant:begin -->
## Memory System (managed by Memophant)

This project uses a layered memory system so any agent session — Claude Code, Codex, Cursor,
Gemini, Copilot, or any other — is productive immediately. Memophant (a macOS app) manages it;
everything is plain files + a native MCP server (`memophant-mcp`) so you can read and write the
memory directly. This block is regenerated between the `memophant` markers — edit anything
outside them freely.

**Use this repo's memory as the single source of truth — every session, any agent.** Read it
before starting work, and record durable decisions and learnings as **notes or wiki pages** —
not in this file, and not in any session-private or model-specific memory — so every session
stays consistent and nothing is lost. Keep `AGENTS.md` and the per-agent shims (`CLAUDE.md` /
`GEMINI.md` / `.github/copilot-instructions.md` / `.cursor/rules/memophant.mdc`) **minimal**:
they point at the memory system, they don't BE the memory system.

**Memory engine — get to know these tools before you start.** Memophant ships an in-repo
native MCP server (`memophant-mcp`) that owns the memory backend end-to-end. When the server
is loaded by your agent, the tools below show up directly. **Before you begin a task, take
stock of the `memophant` MCP tools available in this session and read their descriptions so
you know what each does** — they're how you read and write every tier here, so reach for them
first rather than ad-hoc file reads, greps, or hand-edits. The basic-memory CLI was retired
from production on 2026-06-06; if the MCP tools aren't present in this session, fall back to
grep over `.memory/` and `wiki/` until the server is restored, rather than reaching
for `basic-memory`.

- Native MCP tools (preferred): `search_memories`, `read_memory`, `view_memory`, `write_memory`,
  `edit_memory`, `move_memory`, `delete_memory`, `list_directory`, `list_memory_projects`,
  `recent_activity`, `build_context`. All accept a `project` argument (default
  harness).
- Fallback (only if the MCP tools above are not present in this session): grep `.memory/` and
  `wiki/` directly — `grep -rn "<query>" .memory/ wiki/`.

**1. Memophant Memory (`.memory/`) — structured atomic facts.** A searchable knowledge graph
of observations and relations. Search it before assuming; it is the source of truth for past
decisions and learnings.
- Search: invoke `search_memories(query: "<text>", project: "harness")` via MCP.
- Record durable facts/decisions as you work: `write_memory(title, content, folder, project: "harness")`
  (they're committed with the repo and visible to every session).
- Grammar: each note is markdown with `## Observations` (`- [category] fact text #tag`) and
  `## Relations` (`- relation_type [[Target Note]]`).
- **Filenames are `dashed-slug.md`** — lowercase, hyphen-separated, derived deterministically
  from the title. The display title comes from frontmatter `title:` (always), with the
  prettified filename as a fallback. So title `"GitHub Status Service"` → file
  `github-status-service.md`, and the UI renders `GitHub Status Service`. Use `write_memory`
  for new notes — it slug-generates correctly. **Folder names** are lowercase singular:
  `architecture`, `decisions`, `conventions`, `operations`, `project`, `roadmap`.
- Reindex happens automatically after every write_memory / edit_memory; for direct file edits,
  use the Memophant app's "Reindex" action or restart the MCP server.
- Optional provenance frontmatter — `source_paths` (repo files a note depends on) + `source_sha`
  (HEAD when written) — lets Memory Health flag the note when that code later changes.

**2. Wiki (`wiki/`) — long-form reference docs.** Guides, architecture deep-dives, runbooks, and
design notes. Deliberately kept OUT of this auto-loaded file to save context — search it on demand
rather than reading it wholesale.
- Search: `search_memories(query: "<text>", project: "harness-wiki")` via MCP, or grep:
  `grep -rn "<query>" wiki/`.
- Pages are markdown with dashed filenames; links are `[Title](Page-Name)`. `Home.md` is the
  landing page and `_Sidebar.md` is the navigation.

**Maintaining the wiki.** Update it when work changes user-visible behavior, adds a feature or
service, changes architecture, or ships a release. Skip for bug fixes with no observable change,
pure refactors, typos, and test-only changes.
- The wiki is meant to be publishable, so every commit/publish runs a mandatory two-tier
  secret-scan (token/key patterns block; secret-like assignments warn). **Never commit secrets to
  the wiki.** Details in `wiki/Wiki-Maintenance.md`.

**3. Design (`design/`) — the design system.** A folder of robust design Markdown (design system,
principles, component specs, UX/HIG conventions) you reference before any UI or design work. Kept
OUT of this auto-loaded file to save context — search it on demand.
- Search: `search_memories(query: "<text>", project: "harness-design")` via MCP, or grep:
  `grep -rn "<query>" design/`.
- Plain `.md` files (any name) — add your own or import a design skill; no special structure required.

**4. Code (`code/` + `memophant code` CLI) — structural queries, not blind grep.** The code layer
gives every session a queryable map of THIS repo's source. Two halves: curated `code/` markdown
overviews (module purpose, key types, public surface) for orientation, and an indexed SQLite map
of symbols/imports under `.memophant/code/` (gitignored) for sub-second structural queries.
**Prefer `memophant code <verb>` over `grep` for any structural question** — it's deterministic,
cheap, and saves context. Fall back to `grep` only when the index is stale (see `status`), the
language isn't yet supported (Phase 1 indexes Swift only), or you need a verb that's still Phase 2
(refs / callers / callees).
- **Invocation:** Memophant installs a project-local shim at `./.memophant/code/memophant`. Use
  `memophant code <verb>` if it's on your PATH, otherwise `./.memophant/code/memophant code <verb>`
  from the repo root. (One-time PATH install: `ln -s "$(pwd)/.memophant/code/memophant" ~/.local/bin/memophant`.)
- Find a symbol: `memophant code find <SymbolName>` → file:line of every definition.
- Find references: `memophant code refs <SymbolName>` → every call/use site.
- File outline: `memophant code outline <path>` → the symbol tree inside a file.
- Imports: `memophant code imports <path>` → what a file imports + what imports a file.
- Semantic / curated search: `memophant code search "<intent>"` → FTS over symbols + curated notes.
- Index health: `memophant code status` → `clean | n files stale | rebuilding`, plus HEAD drift.
- Curated overviews: `search_memories(query: "<text>", project: "harness-code")` via MCP, or
  `grep -rn "<query>" code/`. Authored as markdown like wiki/design pages — module purposes,
  architecture maps, "where to start when touching X".
- Symbols + curated notes both surface under `memophant code search`; use it as the default
  structural-discovery verb when you don't already know the symbol name.

**5. Documents (`documents/`) — per-project file store.** Arbitrary files the user or an
agent wants alongside the codebase: PDFs, exported reports, screenshots, source briefs,
scanned receipts — anything that's project context but isn't memory, wiki, design, or code.
Schema-less by design: any file extension is welcome. Browse + open + add via the
Memophant app's Documents tier; the folder is committed with the repo so docs travel with
the project. Phase 1 is browse + open; Phase 2 will add an optional "mine this document for
memory observations" action (Claude reads the document, proposes `.memory/` notes).

**Plans AND generated documents go in `documents/`.** Whenever you produce a file-shaped
artifact for this project — a plan, design proposal, audit report, comparison matrix,
meeting summary, research brief, exported data, analysis write-up, scratch notes the user
asked you to keep — save it under `documents/`. This is the durable home for
agent-generated content; without it, the user has to copy/paste from the chat transcript
to keep anything you produce.
- **Plans** (intent BEFORE action — refactor plans, migration plans, feature scoping,
  architecture proposals): `documents/plans/YYYY-MM-DD-short-kebab-slug.md`. Save BEFORE
  you start executing so the file survives the session and gives the next agent (and
  the user) a permanent record of the intent — not just the diff.
- **Reports / analyses / write-ups** (work output): pick a sensible subfolder by kind —
  `documents/reports/`, `documents/audits/`, `documents/research/`, `documents/exports/`
  — or land flat in `documents/` if no clear category. Same ISO-date kebab-slug filename
  convention.
- **Scratch / drafts**: `documents/scratch/` if the user explicitly asks you to keep
  something rough; otherwise don't write it.
- Default to Markdown (`.md`); use other formats only when the user asks (PDF / CSV /
  JSON / etc. — all welcome, the folder is schema-less).
- This is durable history; `.memory/` is for the eventual SHIPPED decision (after the
  work lands). Code outputs still go in the actual codebase, not here.
- **No credentials or secrets in `documents/`** — the folder is committed with the repo.

**6. Vendors (`vendors/`) — per-project third-party service registry.** Markdown records
(one file per vendor at `vendors/<slug>.md`) with YAML frontmatter for typed fields (name,
type, login_url, signup_url, username, keychain_ref, account_email, monthly_cost, tags)
and a free-form `## Notes` body. Tracks the services this project depends on — payments,
hosting, email, dns, monitoring, analytics, anything billed or credentialed.
- **Credentials live in the iCloud-synced Keychain via the Memophant app, NEVER in the
  vendor file.** The frontmatter's `keychain_ref` field is the NAME of the Keychain item
  (the vendor slug), not the secret. The writer HARD-blocks any save whose serialized form
  contains anything that looks like an API key, JWT, or long-base64 secret — no soft
  warning, no override.
- **Need the actual credential? Call `get_vendor_credential(vendor: "<slug>", project:
  "harness", reason: "<one-line why>")`** instead of asking the user to paste it.
  Memophant pops an in-app consent modal and, on approval, returns the secret in the tool
  result (never echoed to chat). Read fresh from the Keychain each call, so rotations apply
  immediately. Treat it as ONE-SHOT: write it to a `mktemp` file and reference the path in
  later commands — don't echo, log, or persist it. Requires the Memophant app to be running
  (headless/cron sessions time out — use a runtime secret store for those).
- **Created a credential yourself** (minted an API key, got a token from CLI output)? Call
  `set_vendor_credential(vendor: "<slug>", credential: "<secret>", project:
  "harness", reason: "<why>")` to stash it in the Keychain instead of leaving it in
  chat. Memophant asks for approval, creates the vendors/<slug>.md record if it's missing,
  and stores the secret (Keychain only — never the file). Fetch it back later with
  `get_vendor_credential`.
- Search via `search_memories(query: "<text>", project: "harness-vendors")` — the
  tier registers its own engine index, so hybrid search ("which vendor handles
  email?") returns the right hit even when the term lives in notes, not the typed
  frontmatter.
- When you discover a vendor a project uses (via code references, README, env vars), add
  a record via the Memophant app's Vendors tier; don't write the file by hand from an
  agent session unless the user asks — the editor wires up the Keychain credential
  atomically with the file.

**7. Templates (`templates/`) — reusable integration recipes.** Folder-per-template at
`templates/<slug>/` with a required `manifest.md` (YAML frontmatter + canonical body
sections: Prerequisites / Steps / Variables / Verification) and an optional
`reference/` subfolder of verbatim source files from the originating project — kept
as worked examples for the next agent to study, not as substrate to mechanically
`cp` + `sed` into a new project. Templates capture "how we wired Paddle into this
project" so the next project's agent reads the recipe and adapts the patterns to
its own codebase.
- **A template is documentation + recipe, NOT a turn-key install.** The manifest's
  Steps section is narrative prose with 5–10 line inline code snippets for the
  critical signatures, plus pointers at `reference/<file>` for the full
  implementation. The Variables section documents which concepts vary between
  projects (e.g. "BUNDLE_ID — your target project's bundle id; the source project
  used `com.example`"), NOT a substitution table. The next agent reads both and
  decides where in ITS codebase the equivalents go, adapting to its conventions.
- **The `/memophant-template <description>` convention.** When the user types a
  message beginning with `/memophant-template`, treat the remainder as a brief naming
  the integration they want applied to THIS project. Steps: (1) list the repo's `templates/`
  folder to see the available template slugs (or `search_memories(query: "<the integration>",
  project: "harness-templates")` to find the best match — the templates tier isn't
  reachable via `list_directory`/`read_memory`, which only resolve `.memory/`, `wiki/`,
  `design/`, `code/`, and `sessions/`); (2) read the chosen `templates/<slug>/manifest.md`
  directly; (3) read any `reference/` files the Steps point at
  so you understand the shape; (4) confirm the Prerequisites with the user; (5)
  ADAPT each step to this project's codebase — file layout, naming conventions,
  framework choices may differ from the source project; (6) run the Verification
  checks. Plan-first convention applies — write the apply plan to
  `documents/plans/` before executing.
- Search via `search_memories(query: "<text>", project: "harness-templates")` —
  the tier registers its own engine index, so hybrid search ("set up Paddle
  payments") returns the right hit even when the slug is something generic like
  `payments-1`.
- **No raw credentials in manifests or references.** The manifest can carry
  PLACEHOLDER guidance (`{{ PADDLE_API_TOKEN }}`, `<your-key-here>`) in its
  Variables section. Reference files are verbatim source — they SHOULD NOT
  contain real credentials because the original source didn't either (credentials
  live in Vendors/Keychain). Concrete-looking credentials are HARD-blocked by the
  writer in BOTH manifest and reference paths. When a template needs a credential,
  it points at a Vendor record via `vendor_refs:` in the manifest frontmatter —
  the Vendor owns the Keychain item; the template just references it.
- **Creating a template** from an existing project: in the Memophant app, click
  "Extract template from this project…" in the Templates tier header. Pick the
  folders/files that make up the integration; describe what it is in one line;
  Claude reads the source, drafts the four manifest sections (with inline
  snippets for the critical signatures), and includes every selected file as a
  verbatim reference. You review, accept/edit/reject per section, and save.
- **Sharing a template** between projects: copy the `templates/<slug>/` folder from
  one repo into another. The Memophant app surfaces a "Copy to another project…"
  action in a later phase; for now, plain filesystem copy works.

**8. Tasks (`TASKS.md`) — the work board.** A repo-resident kanban in plain Markdown: `## Todo`,
`## Doing`, `## Done` sections, each a checklist (`- [ ]` / `- [x]`). It travels with the repo and
is yours to edit directly.
- **Read `TASKS.md` at the start of work.** When you pick up a task, move its line into `## Doing`;
  when you finish, move it into `## Done` (and flip the checkbox to `- [x]`).
- Add tasks you discover to `## Todo` with a SHORT imperative title — the board card shows the
  title verbatim, so don't pack a paragraph into it. When a task needs real detail, annotate the
  line `(id: t-xxxxxx)` (`t-` + 6 random hex) and create `tasks/t-xxxxxx.md` with frontmatter
  (`id`, `title`, `status: todo`, `added: YYYY-MM-DD`) and a `## Description` holding the detail
  (plus empty `## Plan` / `## Artifacts`). The board shows the title; the card body reads the
  Description. Optional `(source: <note>)` / `(added: YYYY-MM-DD)` line annotations are preserved.
- Memophant renders this as a live kanban, so your edits to `TASKS.md` show up on the board as you
  work — keep it current.
- **A task's status is the section its line sits in — change it by MOVING the line, here in
  `TASKS.md`.** A task may have a detail file at `tasks/<id>.md` carrying a mirrored `status:` /
  `priority:`; that's a Memophant-managed mirror you don't need to touch. (If an out-of-band edit
  makes the two disagree, Memophant reconciles by last-edit-wins — but the board line is canonical.)

**Commits for `.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`,
`vendors/`, `templates/`, and `TASKS.md` are owned by Memophant.** When you write_memory, edit a wiki/design/code page, move a
task on the board, drop a file into `documents/`, or import a session, those files become dirty
in git — **do NOT `git add` or `git commit` them yourself.** The user runs each tier's commit
through Memophant's commit modal, which routes every change through the two-tier secret scan
and stages per-tier paths in isolation (so a stray edit elsewhere can't piggyback into a memory
commit).
- **Yours to commit:** application code, configs, scripts, infrastructure — anything OUTSIDE the
  tier folders above. Use plain `git add` / `git commit` like any other repo.
- **Memophant's to commit:** anything under `.memory/`, `wiki/`, `design/`, `code/`,
  `sessions/`, `documents/`, `vendors/`, `templates/`, and `TASKS.md`. After your task, **leave these files
  dirty** if the work touched them — Memophant's commit bar shows per-tier "uncommitted"
  chips with counts so the user decides when to commit each tier with its own secret-scanned
  message.
- The boundary is by FOLDER, not by your task scope. Editing
  `Memophant/Services/Wiki/PublishWikiSheet.swift` is app code → yours. Editing
  `wiki/Publish-Pipeline.md` is the wiki tier → Memophant's.
- If you find a Memophant-owned file already staged in your session's index, `git restore
  --staged` it before continuing — don't carry it into your commit.
- **Pre-existing dirty Memophant-owned files at session start are normal**, not a problem to
  fix. Memophant batches them into per-tier commits the user makes through the app's commit
  bar. Don't suggest committing them, don't propose discarding them, and don't mention them
  in your end-of-task summary as something for the user to address — the user already knows
  and that's how Memophant works. Treat them as background state when you read `git status`
  to understand the repo. (Exception: if your own work modified the SAME files and you'd
  unintentionally be carrying forward a prior session's abandoned changes, flag that
  specifically.)

**Memophant (the app)** is the management surface: browse, search, and edit notes, wiki and design
pages, track and run tasks on the kanban, migrate existing docs into memory, and commit/publish
with the secret-scan.
<!-- memophant:end -->
