"use strict";
const tabs = [...document.querySelectorAll("[data-demo]")];
let examples;
function selectDemo(tab) {
  if (!examples) return;
  const example = examples[tab.dataset.demo];
  for (const button of tabs) {
    const selected = button === tab;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
  }
  const panel = document.getElementById("demo-panel");
  panel.setAttribute("aria-labelledby", tab.id);
  panel.querySelector(".comment").textContent =
    `# host: Apple M2 · ARM64 macOS 26.6\n# guest: ${example.guest}\n\n`;
  document.getElementById("demo-command").textContent = "$ " + example.command;
  document.getElementById("demo-output").textContent = example.output.trimEnd();
  document.getElementById("copy-demo").dataset.copyText = example.command;
}
if (tabs.length) {
  fetch("demos.json")
    .then((response) => {
      if (!response.ok) throw new Error("Examples unavailable");
      return response.json();
    })
    .then((data) => {
      examples = data;
      selectDemo(tabs[0]);
    })
    .catch(() => {
      for (const tab of tabs) tab.disabled = true;
      // The verified x86 example remains readable if fetching the other examples fails.
    });
  for (const tab of tabs) {
    tab.addEventListener("click", () => selectDemo(tab));
    tab.addEventListener("keydown", (event) => {
      let next;
      const index = tabs.indexOf(tab);
      if (event.key === "ArrowRight") next = tabs[(index + 1) % tabs.length];
      if (event.key === "ArrowLeft")
        next = tabs[(index + tabs.length - 1) % tabs.length];
      if (event.key === "Home") next = tabs[0];
      if (event.key === "End") next = tabs.at(-1);
      if (next) {
        event.preventDefault();
        next.focus();
        selectDemo(next);
      }
    });
  }
}
for (const button of document.querySelectorAll(
  "[data-copy], [data-copy-text]",
)) {
  const label = button.textContent;
  button.addEventListener("click", async () => {
    const text =
      button.dataset.copyText ??
      document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied ✓";
      document.getElementById("copy-status").textContent =
        "Copied to clipboard";
    } catch {
      const range = document.createRange();
      const target = button.dataset.copy
        ? document.getElementById(button.dataset.copy)
        : document.getElementById("demo-command");
      range.selectNodeContents(target);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = "Select + copy";
      document.getElementById("copy-status").textContent =
        "Clipboard unavailable. The command is selected for manual copying.";
    }
    window.setTimeout(() => {
      button.textContent = label;
    }, 2000);
  });
}
