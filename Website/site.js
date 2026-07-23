const previews = {
  working: {
    caption: "Working. Quietly present.",
  },
  approval: {
    caption: "Approval. Enough context to decide.",
  },
  completed: {
    caption: "Completed. Then out of the way.",
  },
};

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const header = document.querySelector("[data-site-header]");
const stage = document.querySelector(".island-stage");
const previewCaption = document.querySelector("#island-caption");
const mockupStates = Array.from(document.querySelectorAll("[data-mockup-state]"));
const previewButtons = Array.from(document.querySelectorAll("[data-preview]"));
const previewNames = previewButtons.map((button) => button.dataset.preview);
let requestedPreview = stage?.dataset.mode ?? "working";
let viewportFrame = 0;

function showPreview(name, { moveFocus = false } = {}) {
  const preview = previews[name];
  if (!preview || !stage || !previewCaption) return;

  requestedPreview = name;

  stage.dataset.mode = name;
  previewCaption.textContent = preview.caption;
  mockupStates.forEach((state) => {
    state.setAttribute("aria-hidden", String(state.dataset.mockupState !== name));
  });

  previewButtons.forEach((button) => {
    const isActive = button.dataset.preview === name;
    button.setAttribute("aria-pressed", String(isActive));
    if (moveFocus && isActive) button.focus();
  });
  if (!reducedMotion.matches) {
    const activeState = mockupStates.find((state) => state.dataset.mockupState === name);
    activeState?.animate(
      [
        { opacity: 0.35, transform: "translateY(-0.35rem) scale(0.965)" },
        { opacity: 1, transform: "translateY(0) scale(1)" },
      ],
      { duration: 280, easing: "cubic-bezier(0.22, 1, 0.36, 1)" },
    );
  }
}

previewButtons.forEach((button) => {
  button.addEventListener("click", () => showPreview(button.dataset.preview));
});

const stateSwitcher = document.querySelector(".state-switcher");
stateSwitcher?.removeAttribute("hidden");
stateSwitcher?.addEventListener("keydown", (event) => {
  const currentIndex = previewNames.indexOf(requestedPreview);
  let nextIndex = currentIndex;

  if (event.key === "ArrowRight" || event.key === "ArrowDown") {
    nextIndex = (currentIndex + 1) % previewNames.length;
  } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
    nextIndex = (currentIndex - 1 + previewNames.length) % previewNames.length;
  } else if (event.key === "Home") {
    nextIndex = 0;
  } else if (event.key === "End") {
    nextIndex = previewNames.length - 1;
  } else {
    return;
  }

  event.preventDefault();
  showPreview(previewNames[nextIndex], { moveFocus: true });
});

const simulator = document.querySelector("[data-simulator]");
const simulatorOpeners = Array.from(document.querySelectorAll("[data-open-simulator]"));
const simulatorCloser = document.querySelector("[data-close-simulator]");
const simulatedCowlick = document.querySelector("[data-sim-cowlick]");
const simulatedTrigger = simulatedCowlick?.querySelector(".sim-notch-trigger");
const simulatedDrawer = document.querySelector("[data-sim-drawer]");
const simulatedScroll = document.querySelector("[data-sim-scroll]");
const simulatedUpdatedLabel = document.querySelector("[data-sim-updated]");
const simulatedToast = document.querySelector("[data-sim-toast]");
const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");
let simulatorReturnFocus = null;
let simulatorHoverTimer = 0;
let simulatorToastTimer = 0;
let simulatorPinned = false;

function simulatorIsExpanded() {
  return simulatedCowlick?.dataset.expanded === "true";
}

function refreshSimulatorState() {
  if (!simulatedUpdatedLabel) return;
  simulatedUpdatedLabel.textContent = "Updated just now";
  simulatedUpdatedLabel.setAttribute("datetime", new Date().toISOString());
}

function setSimulatorExpanded(expanded, { announce = false } = {}) {
  if (!simulatedCowlick || !simulatedTrigger || !simulatedDrawer) return;

  simulatedCowlick.dataset.expanded = String(expanded);
  simulatedTrigger.setAttribute("aria-expanded", String(expanded));
  simulatedDrawer.setAttribute("aria-hidden", String(!expanded));
  simulatedDrawer.inert = !expanded;

  if (expanded) {
    refreshSimulatorState();
  } else if (simulatedScroll) {
    simulatedScroll.scrollTop = 0;
  }

  if (announce) {
    showSimulatorToast(expanded ? "Cowlick expanded with current local state." : "Cowlick minimized.");
  }
}

function showSimulatorToast(message) {
  if (!simulatedToast) return;
  window.clearTimeout(simulatorToastTimer);
  simulatedToast.textContent = message;
  simulatorToastTimer = window.setTimeout(() => {
    simulatedToast.textContent = "";
  }, 2600);
}

function openSimulator(event) {
  if (!simulator) return;
  simulatorReturnFocus = event?.currentTarget ?? document.activeElement;
  refreshSimulatorState();
  document.documentElement.setAttribute("data-simulator-open", "");
  if (typeof simulator.showModal === "function") {
    simulator.showModal();
  } else {
    simulator.setAttribute("open", "");
  }
  window.requestAnimationFrame(() => simulatedTrigger?.focus());
}

function closeSimulator() {
  if (!simulator) return;
  simulatorPinned = false;
  setSimulatorExpanded(false);
  if (typeof simulator.close === "function") {
    simulator.close();
  } else {
    simulator.removeAttribute("open");
    document.documentElement.removeAttribute("data-simulator-open");
    simulatorReturnFocus?.focus?.();
  }
}

simulatorOpeners.forEach((opener) => opener.addEventListener("click", openSimulator));
simulatorCloser?.addEventListener("click", closeSimulator);

simulator?.addEventListener("close", () => {
  document.documentElement.removeAttribute("data-simulator-open");
  simulatorReturnFocus?.focus?.();
  simulatorReturnFocus = null;
});

simulator?.addEventListener("cancel", (event) => {
  if (!simulatorIsExpanded()) return;
  event.preventDefault();
  simulatorPinned = false;
  setSimulatorExpanded(false, { announce: true });
  simulatedTrigger?.focus();
});

simulatedTrigger?.addEventListener("click", (event) => {
  if (!simulatorIsExpanded()) {
    simulatorPinned = true;
    setSimulatorExpanded(true, { announce: event.detail === 0 });
  } else if (simulatorPinned) {
    simulatorPinned = false;
    setSimulatorExpanded(false, { announce: event.detail === 0 });
  } else {
    simulatorPinned = true;
    refreshSimulatorState();
  }
});

simulatedCowlick?.addEventListener("mouseenter", () => {
  if (!finePointer.matches || simulatorPinned) return;
  window.clearTimeout(simulatorHoverTimer);
  simulatorHoverTimer = window.setTimeout(() => setSimulatorExpanded(true), 50);
});

simulatedCowlick?.addEventListener("mouseleave", () => {
  if (!finePointer.matches || simulatorPinned) return;
  window.clearTimeout(simulatorHoverTimer);
  simulatorHoverTimer = window.setTimeout(() => setSimulatorExpanded(false), 160);
});

document.querySelectorAll("[data-sim-action]").forEach((button) => {
  button.addEventListener("click", () => {
    if (button.dataset.simAction === "settings") {
      showSimulatorToast("Settings would open as a separate Cowlick window.");
      return;
    }

    simulatorPinned = false;
    setSimulatorExpanded(false);
    showSimulatorToast("Cowlick quit in the demo. Select the notch to continue trying it.");
    simulatedTrigger?.focus();
  });
});

function updateViewportState() {
  const scrollY = window.scrollY;
  header?.toggleAttribute("data-scrolled", scrollY > 48);

  const marker = window.innerHeight * 0.38;
  let currentSection = null;

  if (scrollY > window.innerHeight * 0.48) {
    document.querySelectorAll(".nav-links a[href^='#']").forEach((link) => {
      const section = document.querySelector(link.getAttribute("href"));
      if (section && section.getBoundingClientRect().top <= marker) currentSection = link;
    });
  }

  document.querySelectorAll(".nav-links a[href^='#']").forEach((link) => {
    if (link === currentSection) {
      link.setAttribute("aria-current", "location");
    } else {
      link.removeAttribute("aria-current");
    }
  });

  viewportFrame = 0;
}

function requestViewportUpdate() {
  if (viewportFrame) return;
  viewportFrame = window.requestAnimationFrame(updateViewportState);
}

window.addEventListener("scroll", requestViewportUpdate, { passive: true });
window.addEventListener("resize", requestViewportUpdate, { passive: true });
updateViewportState();

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.removeAttribute("hidden");
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    const feedback = button.parentElement?.querySelector(".copy-feedback");
    if (!target || !feedback) return;

    window.clearTimeout(button.resetTimer);
    button.disabled = true;
    button.setAttribute("aria-busy", "true");

    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      button.textContent = "Copied";
      feedback.textContent = "Commands copied to the clipboard.";
    } catch {
      feedback.textContent = "Copy was unavailable. Select the commands above instead.";
    } finally {
      button.disabled = false;
      button.removeAttribute("aria-busy");
    }

    button.resetTimer = window.setTimeout(() => {
      button.textContent = "Copy commands";
      feedback.textContent = "";
    }, 3200);
  });
});
