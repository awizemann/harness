# Modules

Curated `code/` overviews — short, opinionated module guides for orientation. The Phase 2
SQLite index already knows the symbols; this folder is for the things grep can't tell you.

## When to add a page

- A major folder gets a new responsibility, and a future session needs the *why* before the *what*.
- You catch yourself explaining the same architectural decision in chat repeatedly.
- A module has a tricky invariant that wouldn't be obvious from `memophant code outline`.

## What NOT to put here

- The list of files in a folder → `memophant code outline <file>` and `memophant code find <Symbol>`.
- Symbol-level docs → Swift's `///` doc comments (the indexer pulls them through).
- Bugs / todos / follow-ups → `TASKS.md`.
- Project-wide decisions and conventions → `.memory/` notes.

## Suggested first pages

Whatever a new contributor would need to read first. A ~100-line markdown overview per
top-level module beats a 1000-line "everything" document. Search this folder via the
`memophant` MCP server (`search_memories "<query>" --project <bm>-code`) or grep `code/`.