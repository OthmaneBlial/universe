#!/usr/bin/env python3
"""Check portable site links, snippet targets and the recorded guest outputs."""
import json
import re
import shlex
import subprocess
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.ids, self.links, self.copies, self.demos = set(), [], [], set()
        self.feed(source.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if key in attrs:
                self.links.append(attrs[key])
        if "data-copy" in attrs:
            self.copies.append(attrs["data-copy"])
        if "data-demo" in attrs:
            self.demos.add(attrs["data-demo"])


def main():
    pages = {path: Page(path) for path in SITE.glob("*.html")}
    checked = 0
    for path, page in pages.items():
        assert set(page.copies) <= page.ids, f"Missing snippet in {path.name}"
        assert "copy-status" in page.ids, f"Missing copy feedback in {path.name}"
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            assert not url.path.startswith("/"), f"Root-relative URL: {link}"
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if target.is_dir():
                target /= "index.html"
            assert target.is_relative_to(SITE), f"URL escapes site: {link}"
            assert target.is_file(), f"Missing asset: {link}"
            if url.fragment:
                assert target in pages and unquote(url.fragment) in pages[target].ids, link
            checked += 1
    for link in re.findall(r"url\(['\"]?([^)'\"]+)", (SITE / "styles.css").read_text()):
        assert not link.startswith("/") and (SITE / link).is_file(), link
    for path in (SITE / "assets").glob("*.svg"):
        ElementTree.parse(path)
    ElementTree.parse(ROOT / "docs/assets/universe-banner.svg")
    demos = json.loads((SITE / "demos.json").read_text())
    assert set(demos) == pages[SITE / "index.html"].demos
    for key, demo in demos.items():
        command = shlex.split(demo["command"])
        assert command[0] == "./zig-out/bin/universe", key
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=15)
        assert (result.returncode, result.stdout) == (demo["exit_code"], demo["output"]), key
        assert not result.stderr, (key, result.stderr)
    print(f"Site: {len(pages)} pages, {checked} local URLs, SVGs and {len(demos)} real guest outputs verified")


if __name__ == "__main__":
    main()
