// Harness landing — minimal. Adds a small "copied" affordance to <pre.code> blocks.
(function () {
  const blocks = document.querySelectorAll("pre.code");
  if (!blocks.length || !navigator.clipboard) return;

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
})();
