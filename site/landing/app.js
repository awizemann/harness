// Harness landing — minimal client behavior. No dependencies.
//   1. Theme toggle (override prefers-color-scheme; persisted in localStorage)
//   2. Light/dark image swap on <img data-dark-src>
//   3. "Copy" button affordance on <pre.code> blocks

(function () {
  const root = document.documentElement;
  const STORAGE_KEY = "harness-theme";

  // ---- 1. Theme toggle ---------------------------------------------------

  function applyTheme(theme) {
    if (theme === "light" || theme === "dark") {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
    applyImageTheme();
  }

  function resolveTheme() {
    const explicit = root.getAttribute("data-theme");
    if (explicit === "light" || explicit === "dark") return explicit;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  // ---- 2. Light/dark image swap -----------------------------------------
  // Each <img> with data-dark-src holds its dark variant. We cache the
  // initial light src on data-light-src and swap based on resolveTheme().
  function applyImageTheme() {
    const theme = resolveTheme();
    document.querySelectorAll("img[data-dark-src]").forEach((img) => {
      if (!img.dataset.lightSrc) {
        img.dataset.lightSrc = img.getAttribute("src");
      }
      const target = theme === "dark" ? img.dataset.darkSrc : img.dataset.lightSrc;
      if (img.getAttribute("src") !== target) img.setAttribute("src", target);
      const picture = img.parentElement;
      if (picture && picture.tagName === "PICTURE") {
        picture.querySelectorAll("source").forEach((s) => {
          if (s.getAttribute("srcset") !== target) s.setAttribute("srcset", target);
        });
      }
    });
  }

  // Hydrate stored preference (if any)
  let stored = null;
  try {
    stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "light" || stored === "dark") applyTheme(stored);
    else applyImageTheme();
  } catch (_) {
    applyImageTheme();
  }

  const toggle = document.querySelector("[data-theme-toggle]");
  if (toggle) {
    toggle.addEventListener("click", () => {
      const current = root.getAttribute("data-theme");
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      let next;
      if (current === "light") next = "dark";
      else if (current === "dark") next = null; // back to system default
      else next = prefersDark ? "light" : "dark";

      applyTheme(next);
      try {
        if (next) localStorage.setItem(STORAGE_KEY, next);
        else localStorage.removeItem(STORAGE_KEY);
      } catch (_) { /* ignore */ }
    });
  }

  // Re-apply on system preference change for users without an explicit override
  if (window.matchMedia) {
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => {
      if (!root.hasAttribute("data-theme")) applyImageTheme();
    };
    if (mql.addEventListener) mql.addEventListener("change", onChange);
    else if (mql.addListener) mql.addListener(onChange);
  }

  // ---- 3. Copy buttons on code blocks -----------------------------------
  const blocks = document.querySelectorAll("pre.code");
  if (blocks.length && navigator.clipboard) {
    for (const pre of blocks) {
      pre.style.position = "relative";
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = "Copy";
      btn.setAttribute("aria-label", "Copy code to clipboard");
      Object.assign(btn.style, {
        position: "absolute",
        top: "0.5rem",
        right: "0.5rem",
        padding: "0.25rem 0.6rem",
        fontSize: "0.78rem",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius-sm)",
        background: "var(--bg-3)",
        color: "var(--text-2)",
        cursor: "pointer",
        fontFamily: "var(--font-sans)",
      });
      btn.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(pre.innerText);
          const original = btn.textContent;
          btn.textContent = "Copied";
          btn.style.color = "var(--accent)";
          setTimeout(() => {
            btn.textContent = original;
            btn.style.color = "var(--text-2)";
          }, 1400);
        } catch {
          btn.textContent = "Failed";
          setTimeout(() => { btn.textContent = "Copy"; }, 1400);
        }
      });
      pre.appendChild(btn);
    }
  }
})();
