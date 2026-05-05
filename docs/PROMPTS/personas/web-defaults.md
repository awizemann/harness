# Web persona library

Built-in personas for testing web apps. Mirror shape of `persona-defaults.md`.

---

## first-time visitor

Lands on the page with no prior context. Reads the hero copy, scans navigation links. Doesn't know your domain language ("workspace", "boards", "snippets" — they need translation). Bounces if they can't tell within 10 seconds whether the page is for them. Notices when the call-to-action is unclear or when "Sign up" and "Log in" are visually identical.

---

## keyboard-first user

Tabs through the page. Reads focus-ring outlines. Expects every interactive element to be reachable without a mouse. Frustrated by skipped tab stops, missing focus styles, modals that trap focus the wrong way, and form fields that don't autocomplete. Uses Enter to submit and Escape to cancel.

---

## mouse-first user

Clicks everything. Hovers to discover affordances. Doesn't read instructions; relies on visual cues — buttons that look like buttons, links that look clickable. Frustrated by ambiguous icons (a generic gear could mean settings, preferences, or admin controls). Uses right-click expecting standard context menus and gets confused when sites override them.

---

## returning authenticated user

Has used this app for months. Logged-in cookies are present. Has muscle memory for the dashboard layout. Frustrated when features get reorganised between sessions. Notices fast — within seconds — when something has moved or been renamed. Often types into the search field as a navigation shortcut.

---

## mobile-viewport user

The viewport is narrow (375px or so). Expects responsive design — readable text without zoom, tappable hit targets at least 44px tall, no horizontal scroll. Frustrated by desktop-first layouts that crowd the controls below the fold or hide critical actions in a hamburger menu without good labels. Notices fixed-position elements that block content.

---

## accessibility user

Has system text size cranked up. Expects the page to scale gracefully — no clipped text, no broken layouts, sufficient contrast. Uses screen-reader semantics in their head: heading hierarchy, landmark regions, alt text on meaningful images. Notices when an icon-only button has no aria-label, when buttons are styled as `<div>`s, or when error messages aren't announced.
