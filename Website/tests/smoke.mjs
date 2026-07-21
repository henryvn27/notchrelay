import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const websiteDirectory = dirname(dirname(fileURLToPath(import.meta.url)));
const buildDirectory = join(websiteDirectory, "..", "build", "website");
const mimeTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
  [".xml", "application/xml; charset=utf-8"],
]);

function resolveRequestPath(requestURL) {
  const pathname = new URL(requestURL, "http://127.0.0.1").pathname;
  const relativePath =
    pathname === "/cowlick/" ? "index.html" : pathname.replace(/^\/cowlick\//, "");
  const normalizedPath = normalize(relativePath);
  if (normalizedPath.startsWith("..") || normalizedPath.startsWith("/")) return null;
  return join(buildDirectory, normalizedPath);
}

const server = createServer(async (request, response) => {
  const requestPath = resolveRequestPath(request.url ?? "/");
  if (!requestPath) {
    response.writeHead(400).end("Bad request");
    return;
  }

  try {
    const metadata = await stat(requestPath);
    if (!metadata.isFile()) throw new Error("Not a file");
    const body = await readFile(requestPath);
    response.writeHead(200, {
      "Content-Length": body.length,
      "Content-Type": mimeTypes.get(extname(requestPath)) ?? "application/octet-stream",
    });
    response.end(body);
  } catch {
    response.writeHead(404).end("Not found");
  }
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
assert(address && typeof address !== "string");
const origin = `http://127.0.0.1:${address.port}`;
const pageURL = `${origin}/cowlick/`;
const browserChannel = process.env.COWLICK_PLAYWRIGHT_CHANNEL;
const browser = await chromium.launch({
  headless: true,
  ...(browserChannel ? { channel: browserChannel } : {}),
});

try {
  const context = await browser.newContext({
    permissions: ["clipboard-read", "clipboard-write"],
    viewport: { width: 1_440, height: 1_000 },
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const externalRequests = [];
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("request", (request) => {
    if (!request.url().startsWith(origin)) externalRequests.push(request.url());
  });

  await page.goto(pageURL, { waitUntil: "networkidle" });
  assert.equal(await page.title(), "Cowlick - Codex at the MacBook notch");
  assert.equal(
    await page.getByRole("heading", { level: 1 }).textContent(),
    "Codex lives at the notch."
  );
  assert.equal(
    await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth),
    0
  );
  assert.deepEqual(consoleErrors, []);
  assert.deepEqual(externalRequests, []);
  assert(
    await page.locator("img").evaluateAll((images) =>
      images.every((image) => image.complete && image.naturalWidth > 0)
    )
  );

  const preview = page.locator("#island-preview");
  await page.locator("[data-mockup-state='working']:visible").waitFor();
  assert.equal(await preview.locator("img").count(), 0);
  assert.match(await preview.textContent(), /Scoutly.*Working/s);
  assert.equal(await page.locator(".state-switcher").getAttribute("aria-describedby"), "state-switcher-help");
  assert.match(
    await page.locator(".demo-provenance").textContent(),
    /Interactive Cowlick mockup · Built from the product's real states/
  );
  await page.locator(".macbook-screen").waitFor();
  await page.locator(".screen-notch").waitFor();
  await page.locator(".macbook-base").waitFor();
  assert.match(
    await page.locator(".usage-capture figcaption").textContent(),
    /July 20, 2026.*third-party data.*not a\s+Cowlick estimate/s,
  );
  assert.match(await page.getByLabel("Supported systems").textContent(), /macOS 14\+/);
  assert.match(
    await page.getByLabel("Supported systems").textContent(),
    /Universal Apple silicon \+ Intel build targets/
  );
  assert.match(await page.getByLabel("Supported systems").textContent(), /fallback without a notch/);

  const approval = page.getByRole("button", { name: "Approval" });
  await approval.click();
  await page.locator(".island-stage[data-mode='approval']").waitFor();
  assert.equal(await approval.getAttribute("aria-pressed"), "true");
  assert.match(await preview.textContent(), /Ship the verified release.*Allow once/s);
  assert.equal(
    await page.locator("[data-mockup-state='approval']").getAttribute("aria-hidden"),
    "false"
  );

  const completed = page.getByRole("button", { name: "Completed" });
  await completed.click();
  await page.locator(".island-stage[data-mode='completed']").waitFor();
  assert.equal(await completed.getAttribute("aria-pressed"), "true");
  assert.match(await preview.textContent(), /Meetily.*Completed/s);

  const working = page.getByRole("button", { name: "Working" });
  await working.click();
  await page.locator(".island-stage[data-mode='working']").waitFor();
  await working.press("ArrowRight");
  await page.locator(".island-stage[data-mode='approval']").waitFor();
  assert.equal(await approval.getAttribute("aria-pressed"), "true");
  assert.equal(await approval.evaluate((button) => button === document.activeElement), true);
  await approval.press("End");
  await page.locator(".island-stage[data-mode='completed']").waitFor();
  assert.equal(await completed.getAttribute("aria-pressed"), "true");
  assert.equal(await completed.evaluate((button) => button === document.activeElement), true);

  await page.locator("#product").evaluate((section) => section.scrollIntoView());
  await page.locator("[data-site-header][data-scrolled]").waitFor();
  await page.locator(".nav-links a[href='#product'][aria-current='location']").waitFor();

  const copyButton = page.getByRole("button", { name: "Copy commands" });
  await copyButton.click();
  await page.getByRole("status").getByText("Commands copied to the clipboard.").waitFor();

  for (const viewport of [
    { width: 390, height: 844 },
    { width: 768, height: 900 },
    { width: 1_024, height: 900 },
    { width: 1_440, height: 1_000 },
  ]) {
    await page.setViewportSize(viewport);
    assert.equal(
      await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth),
      0
    );
    await assertInsideViewport(page.getByRole("link", { name: /Build from source/ }), viewport.width);
    await assertInsideViewport(page.locator(".macbook"), viewport.width);
    await assertCenteredNotch(page);
  }

  await page.setViewportSize({ width: 390, height: 844 });
  await approval.click();
  await page.locator(".island-stage[data-mode='approval']").waitFor();
  await assertInsideViewport(preview, 390);
  await assertMinimumTarget(page.getByRole("button", { name: "Working" }));
  await assertMinimumTarget(approval);
  await assertMinimumTarget(completed);
  await context.close();

  const reducedMotionContext = await browser.newContext({
    reducedMotion: "reduce",
    viewport: { width: 1_024, height: 900 },
  });
  const reducedMotionPage = await reducedMotionContext.newPage();
  await reducedMotionPage.goto(pageURL);
  await reducedMotionPage.getByRole("button", { name: "Approval" }).click();
  await reducedMotionPage.getByRole("button", { name: "Completed" }).click();
  await reducedMotionPage.locator(".island-stage[data-mode='completed']").waitFor();
  assert.match(await reducedMotionPage.locator("#island-caption").textContent(), /Completed\./);
  assert.equal(
    await reducedMotionPage.getByRole("button", { name: "Completed" }).getAttribute("aria-pressed"),
    "true"
  );
  await reducedMotionPage.waitForTimeout(50);
  assert.equal(
    await reducedMotionPage
      .locator("[data-mockup-state='completed']")
      .evaluate((state) => state.getAnimations().filter((animation) => animation.playState === "running").length),
    0
  );
  await reducedMotionContext.close();

  const noScriptContext = await browser.newContext({
    javaScriptEnabled: false,
    viewport: { width: 390, height: 844 },
  });
  const noScriptPage = await noScriptContext.newPage();
  await noScriptPage.goto(pageURL);
  assert.equal(
    await noScriptPage.getByRole("heading", { level: 1 }).textContent(),
    "Codex lives at the notch."
  );
  assert.equal(
    await noScriptPage.evaluate(() => document.documentElement.scrollWidth - window.innerWidth),
    0
  );
  assert.equal(
    await noScriptPage.locator(".state-switcher").evaluate((element) => getComputedStyle(element).display),
    "none"
  );
  assert.equal(
    await noScriptPage.locator(".copy-command").evaluate((element) => getComputedStyle(element).display),
    "none"
  );
  assert.equal(await noScriptPage.locator("main section:visible").count(), 6);
  await noScriptContext.close();
} finally {
  await browser.close();
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve()))
  );
}

console.log("Cowlick website browser smoke passed.");

async function assertInsideViewport(locator, viewportWidth) {
  const box = await locator.boundingBox();
  assert(box);
  assert(box.x >= 0);
  assert(box.x + box.width <= viewportWidth);
}

async function assertMinimumTarget(locator) {
  const box = await locator.boundingBox();
  assert(box);
  assert(box.width >= 44);
  assert(box.height >= 44);
}

async function assertCenteredNotch(page) {
  const geometry = await page.evaluate(() => {
    const screen = document.querySelector(".macbook-screen").getBoundingClientRect();
    const notch = document.querySelector(".screen-notch").getBoundingClientRect();
    const stageTransform = getComputedStyle(document.querySelector(".island-stage")).transform;
    return {
      centerDelta: Math.abs(screen.x + screen.width / 2 - (notch.x + notch.width / 2)),
      notchShare: notch.width / screen.width,
      stageTransform,
    };
  });
  assert(geometry.centerDelta < 1);
  assert(geometry.notchShare > 0.1 && geometry.notchShare < 0.35);
  assert(!geometry.stageTransform.startsWith("matrix3d"));
}
