# Wiki Maintenance

This wiki is the long-form reference for the project. It lives in the `wiki/` folder in the main
repo and travels with the code. Memophant is the management surface (browse, edit, create, commit),
but the pages are plain Markdown you can edit with any tool.

## Page conventions

- **Filenames** use dashes for spaces (`Architecture-Overview.md`).
- **Internal links** use Markdown with the dashed name: `[Architecture Overview](Architecture-Overview)`.
- Every page **ends with** a line like `_Last updated: YYYY-MM-DD — <note>_`. Stubs use `— stub`.
- `Home.md` is the landing page, `_Sidebar.md` is the grouped nav, `_Footer.md` is the footer.

## The secret-scan (why pushes can be blocked)

The wiki is meant to be publishable, so every commit/publish runs a two-tier secret-scan:

- **Hard tier** — token and private-key patterns (OpenAI/Anthropic-style keys, GitHub tokens and
  fine-grained PATs, Slack tokens, AWS access keys, Google API keys, private-key and OpenSSH key
  headers) plus a user blocklist. Any match **blocks** the commit.
- **Soft tier** — assignment-style lines whose key name looks like a secret (password, api key,
  secret key, token, auth token, bearer). These **warn** and require an explicit override to proceed.
  This page is exempt because it names those terms on purpose.
- **User blocklist** at `.memophant/wiki-blocklist.txt` (gitignored): one literal pattern per line
  (personal IPs / hostnames). Lines starting with `#` and blank lines are ignored. Matches are hard blocks.

Never put real keys, tokens, private keys, `.env` contents, or personal hostnames/IPs in the wiki.

## Publishing to the GitHub Wiki

Publishing is automatic and owned by Memophant. Committing the `wiki/` tier through Memophant runs
the two-tier secret-scan above, then mirrors `wiki/` to the GitHub Wiki
(`awizemann/harness.wiki.git`) as a `docs(wiki): sync from wiki/ (<sha>)` commit.

`wiki/` is the **single source of truth**; the live Wiki is a pure mirror of it. Edit only `wiki/`
— never the published copy directly, or the next sync reverts your change. There is no separate
publish script.

---
_Last updated: 2026-07-21 — Memophant is the sole publish pipeline_