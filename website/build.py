#!/usr/bin/env python3
"""Renders the downloads page: index.html with a row for every release.

    python3 website/build.py --out DIR [--releases FILE] [--local DIR]

--releases  JSON as GitHub's "list releases" API returns it. One row for each
            published release that has a disk image or a zip attached.
--local     A folder of packages made by scripts/package.sh. They are listed
            first and linked to as downloads/<file>; DIR/downloads is made to
            point at the folder so that those links work when DIR is served.
"""

import argparse
import html
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

TEMPLATE = Path(__file__).resolve().parent / "index.html"
MARKER = "<!-- releases -->"
PACKAGE = re.compile(r"^Retainer-(?P<version>.+)-(?P<build>[^-]+)\.(?P<kind>dmg|zip)$")


def published_rows(path):
    rows = []
    for release in json.loads(Path(path).read_text(encoding="utf-8")):
        if release.get("draft"):
            continue
        links = {}
        for asset in release.get("assets", []):
            kind = asset["name"].rpartition(".")[2]
            if kind in ("dmg", "zip"):
                links.setdefault(kind, asset["browser_download_url"])
        if links:
            when = release.get("published_at") or release.get("created_at") or ""
            rows.append((when, release.get("name") or release["tag_name"], links))
    rows.sort(key=lambda row: row[0], reverse=True)
    return [(name, links, when) for when, name, links in rows]


def local_rows(folder):
    packages = {}
    for file in Path(folder).iterdir():
        match = PACKAGE.match(file.name)
        if match and file.is_file():
            key = (match["version"], match["build"])
            entry = packages.setdefault(key, {"links": {}, "modified": 0.0})
            entry["links"][match["kind"]] = "downloads/" + quote(file.name)
            entry["modified"] = max(entry["modified"], file.stat().st_mtime)
    newest_first = sorted(packages.items(), key=lambda item: item[1]["modified"], reverse=True)
    return [
        (
            "Retainer %s (%s)" % key,
            entry["links"],
            datetime.fromtimestamp(entry["modified"], timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        )
        for key, entry in newest_first
    ]


def render(rows):
    if not rows:
        return '    <tr><td class="none">No releases yet</td></tr>'
    lines = []
    for name, links, when in rows:
        # The disk image is the download; the zip is offered beside it. With
        # only one of the two, that one is the download.
        kinds = [kind for kind in ("dmg", "zip") if kind in links]
        anchors = '<a href="%s">Download</a>' % html.escape(links[kinds[0]])
        for kind in kinds[1:]:
            anchors += '<a class="mirror" href="%s">(%s)</a>' % (html.escape(links[kind]), kind)
        # `when` is a moment in UTC. The page shows its date, and a script in
        # index.html turns that into the date where the reader is.
        date = '<time datetime="%s">%s</time>' % (html.escape(when), html.escape(when[:10])) if when else ""
        lines += [
            "    <tr>",
            '      <td class="version">%s</td>' % html.escape(name),
            '      <td class="get">%s</td>' % anchors,
            '      <td class="date">%s</td>' % date,
            "    </tr>",
        ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Renders the downloads page.")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--releases", type=Path)
    parser.add_argument("--local", type=Path)
    arguments = parser.parse_args()

    template = TEMPLATE.read_text(encoding="utf-8")
    if MARKER not in template:
        sys.exit("error: %s has no %s line to put the releases in." % (TEMPLATE, MARKER))

    rows = []
    if arguments.local and arguments.local.is_dir():
        rows += local_rows(arguments.local)
    if arguments.releases:
        rows += published_rows(arguments.releases)

    arguments.out.mkdir(parents=True, exist_ok=True)
    (arguments.out / "index.html").write_text(template.replace(MARKER, render(rows)), encoding="utf-8")

    if arguments.local and arguments.local.is_dir():
        link = arguments.out / "downloads"
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            sys.exit("error: %s is in the way of the link to %s." % (link, arguments.local))
        link.symlink_to(arguments.local.resolve(), target_is_directory=True)

    print("Rendered %s with %d release%s." % (arguments.out / "index.html", len(rows), "" if len(rows) == 1 else "s"))


if __name__ == "__main__":
    main()
