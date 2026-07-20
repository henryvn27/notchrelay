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

  const approval = page.getByRole("button", { name: "Approval" });
  await approval.click();
  assert.equal(await approval.getAttribute("aria-pressed"), "true");
  assert.equal(await page.locator("#island-preview").getAttribute("src"), "./assets/approval.png");

  const completed = page.getByRole("button", { name: "Completed" });
  await completed.click();
  assert.equal(await completed.getAttribute("aria-pressed"), "true");
  assert.equal(await page.locator("#island-preview").getAttribute("src"), "./assets/completed.png");

  const copyButton = page.getByRole("button", { name: "Copy commands" });
  await copyButton.click();
  await page.getByRole("status").getByText("Commands copied to the clipboard.").waitFor();

  await page.setViewportSize({ width: 390, height: 844 });
  await approval.click();
  assert.equal(await approval.getAttribute("aria-pressed"), "true");
  assert.equal(
    await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth),
    0
  );
  await context.close();

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
