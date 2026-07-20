const previews = {
  working: {
    src: "./assets/working.png",
    width: 340,
    height: 68,
    alt: "Cowlick showing the ActivityPilot project in its working state",
    caption: "Working. Quietly present.",
  },
  approval: {
    src: "./assets/approval.png",
    width: 760,
    height: 282,
    alt: "Cowlick showing a request-matched Bash approval with explicit Deny and Allow once actions",
    caption: "Approval. Enough context to decide.",
  },
  completed: {
    src: "./assets/completed.png",
    width: 340,
    height: 68,
    alt: "Cowlick showing the ActivityPilot project as completed",
    caption: "Completed. Then out of the way.",
  },
};

const stage = document.querySelector(".island-stage");
const previewImage = document.querySelector("#island-preview");
const previewCaption = document.querySelector("#island-caption");
const previewButtons = Array.from(document.querySelectorAll("[data-preview]"));

function showPreview(name) {
  const preview = previews[name];
  if (!preview || !stage || !previewImage || !previewCaption) return;

  stage.dataset.mode = name;
  previewImage.src = preview.src;
  previewImage.width = preview.width;
  previewImage.height = preview.height;
  previewImage.alt = preview.alt;
  previewCaption.textContent = preview.caption;

  previewButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.preview === name));
  });
}

previewButtons.forEach((button) => {
  button.addEventListener("click", () => showPreview(button.dataset.preview));
});

document.querySelector(".state-switcher")?.removeAttribute("hidden");

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.removeAttribute("hidden");
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    const feedback = button.parentElement?.querySelector(".copy-feedback");
    if (!target || !feedback) return;

    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      button.textContent = "Copied";
      feedback.textContent = "Commands copied to the clipboard.";
    } catch {
      feedback.textContent = "Copy was unavailable. Select the commands above instead.";
    }

    window.setTimeout(() => {
      button.textContent = "Copy commands";
      feedback.textContent = "";
    }, 3200);
  });
});
