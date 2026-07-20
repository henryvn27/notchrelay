#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
WEBSITE_ROOT = REPOSITORY_ROOT / "build" / "website"


class WebsiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.references: list[tuple[str, str, str]] = []
        self.images: list[dict[str, str]] = []
        self.buttons: list[dict[str, str]] = []
        self.headings: list[str] = []
        self.landmarks: set[str] = set()
        self.html_language: str | None = None
        self.csp: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}
        if identifier := values.get("id"):
            self.ids.add(identifier)
        if tag in {"header", "main", "nav", "footer"}:
            self.landmarks.add(tag)
        if tag == "html":
            self.html_language = values.get("lang")
        if tag == "meta" and values.get("http-equiv", "").lower() == "content-security-policy":
            self.csp = values.get("content")
        if tag == "img":
            self.images.append(values)
        if tag == "button":
            self.buttons.append(values)
        if tag == "h1":
            self.headings.append(tag)
        for attribute in ("href", "src"):
            if value := values.get(attribute):
                self.references.append((tag, attribute, value))


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def verify() -> list[str]:
    failures: list[str] = []
    index_path = WEBSITE_ROOT / "index.html"
    if not index_path.is_file():
        return [f"missing built website: {index_path}"]

    html = index_path.read_text(encoding="utf-8")
    css = (WEBSITE_ROOT / "styles.css").read_text(encoding="utf-8")
    javascript = (WEBSITE_ROOT / "site.js").read_text(encoding="utf-8")
    parser = WebsiteParser()
    parser.feed(html)

    if parser.html_language != "en":
        failures.append("html must declare lang=en")
    if len(parser.headings) != 1:
        failures.append(f"expected one h1, found {len(parser.headings)}")
    missing_landmarks = {"header", "main", "nav", "footer"} - parser.landmarks
    if missing_landmarks:
        failures.append(f"missing semantic landmarks: {sorted(missing_landmarks)}")
    if not parser.csp:
        failures.append("missing Content-Security-Policy meta element")
    else:
        directives: dict[str, list[str]] = {}
        duplicate_directives: set[str] = set()
        for directive in parser.csp.split(";"):
            parts = directive.strip().split()
            if not parts:
                continue
            name = parts[0]
            if name in directives:
                duplicate_directives.add(name)
            else:
                directives[name] = parts[1:]
        if duplicate_directives:
            failures.append(f"CSP contains duplicate directives: {sorted(duplicate_directives)}")
        if directives.get("connect-src") != ["'none'"]:
            failures.append("CSP connect-src directive must be exactly 'none'")
    if "—" in html:
        failures.append("marketing copy contains an em dash")
    if "releases/latest/download" in html:
        failures.append("website must not link to an unpublished release asset")
    if "[hidden]" not in css or "display: none !important" not in css:
        failures.append("CSS must preserve hidden controls when JavaScript is unavailable")
    if "setInterval" in javascript:
        failures.append("website state previews must not autoplay")

    for image in parser.images:
        for attribute in ("src", "alt", "width", "height"):
            if attribute not in image:
                failures.append(f"image is missing {attribute}: {image.get('src', '<unknown>')}")

    for button in parser.buttons:
        if button.get("type") != "button":
            failures.append(f"button must declare type=button: {button}")

    for tag, attribute, reference in parser.references:
        parsed = urlparse(reference)
        if parsed.scheme in {"http", "https", "mailto"}:
            continue
        if reference.startswith("/"):
            failures.append(f"project-root-relative URL is not Pages-safe: {reference}")
            continue
        if reference.startswith("#"):
            if reference[1:] not in parser.ids:
                failures.append(f"missing fragment target: {reference}")
            continue
        local_path = (WEBSITE_ROOT / parsed.path).resolve()
        try:
            local_path.relative_to(WEBSITE_ROOT.resolve())
        except ValueError:
            failures.append(f"reference escapes website output: {reference}")
            continue
        if not local_path.is_file():
            failures.append(f"missing local {tag} {attribute}: {reference}")

    asset_pairs = {
        "Assets/AppIcon/cowlick-icon.svg": "cowlick-icon.svg",
        "Assets/AppIcon/cowlick-icon-1024.png": "cowlick-icon-1024.png",
        "Assets/Screenshots/working.png": "working.png",
        "Assets/Screenshots/approval.png": "approval.png",
        "Assets/Screenshots/completed.png": "completed.png",
        "Assets/Screenshots/multi-session.png": "multi-session.png",
        "Assets/Screenshots/usage.png": "usage.png",
        "Assets/Social/github-social-preview.png": "github-social-preview.png",
    }
    for source, destination in asset_pairs.items():
        source_path = REPOSITORY_ROOT / source
        destination_path = WEBSITE_ROOT / "assets" / destination
        if not destination_path.is_file() or digest(source_path) != digest(destination_path):
            failures.append(f"website asset drifted from canonical source: {destination}")

    if any(path.is_symlink() for path in WEBSITE_ROOT.rglob("*")):
        failures.append("website output contains a symbolic link")

    return failures


if __name__ == "__main__":
    errors = verify()
    if errors:
        for error in errors:
            print(f"website verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("Website structure, local links, assets, CSP, and Pages paths verified.")
