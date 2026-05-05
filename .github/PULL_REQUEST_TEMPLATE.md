## Summary

<!-- One paragraph: what this changes and why. -->

## Standards touched

<!-- Per CONTRIBUTING.md, name the standards numbers this PR touches. e.g. "Standards: 03, 13, 14". -->

Standards:

## Public surfaces touched

Check every surface this PR affects. If a box is checked but the corresponding update is missing, the PR isn't ready.

- [ ] `README.md` — user-visible feature, screenshot, version bump, or status change
- [ ] [GitHub Wiki](https://github.com/awizemann/harness/wiki) — new service, feature module, tool schema, run-log format, friction kind, or standards index
- [ ] `site/landing/` — landing page copy, hero, screenshots, or new top-level capability
- [ ] `standards/` — amended a standard (and updated [Standards-Index](https://github.com/awizemann/harness/wiki/Standards-Index))
- [ ] None of the above (bug fix, refactor, typo, internal cleanup, test-only)

## Verification

- [ ] `xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug build` succeeds
- [ ] `xcodebuild test -project Harness.xcodeproj -scheme Harness` passes (or N/A)
- [ ] For non-trivial changes: ran [`standards/AUDIT_CHECKLIST.md`](../standards/AUDIT_CHECKLIST.md)

## Notes for reviewer

<!-- Anything tricky, anything you want extra eyes on, anything explicitly out of scope. -->
