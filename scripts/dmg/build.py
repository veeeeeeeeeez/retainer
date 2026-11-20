"""Makes the disk image, with the window that shows where to drag the app.

    python scripts/dmg/build.py <Retainer.app> <output.dmg>

Run by scripts/package.sh, with the Python it sets up from requirements.txt.
dmgbuild does the work. It writes the window's layout straight into the
image, so the Finder is not involved and a build machine with nobody at it
gives the same result as a Mac with someone watching.
"""

import os
import plistlib
import subprocess
import sys
import tempfile

import dmgbuild
import dmgbuild.core
from ds_store import DSStore
from mac_alias import Alias

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
VOLUME = "Retainer"

# Sizes are in points. They are also in scripts/make-dmg-background.swift,
# which draws the picture to fit them: change them in both.
INSIDE = (600, 400)
TITLE_BAR = 28
APP_CENTRE = (165, 160)
APPLICATIONS_CENTRE = (435, 160)


class NoBookmark:
    """Stands in for mac_alias.Bookmark, so that the picture is recorded one way only.

    dmgbuild 1.6.5 records where the picture is twice, as an alias and as a
    bookmark. Recent Finders (those of macOS 15.7 and 26, at least) go by the
    bookmark, look for the picture in the wrong place, and show the window
    with no picture at all. With the alias alone, every version finds it.
    dmgbuild 1.6.7 dropped the bookmark itself, but needs a newer Python than
    the one macOS provides.
    """

    @staticmethod
    def for_file(path):
        return None


def build(app, output):
    name = os.path.basename(app)
    dmgbuild.core.Bookmark = NoBookmark
    dmgbuild.build_dmg(
        filename=output,
        volume_name=VOLUME,
        settings={
            "format": "UDZO",
            # Apple's advice for a window with a picture behind it: the
            # feature was made for this file system and is at its most
            # dependable there.
            "filesystem": "HFS+",
            # Nothing is set on the app itself, such as hiding its extension
            # (which the Finder does for an app anyway): that is written
            # onto the bundle, and the bundle's signature no longer checks.
            "files": [app],
            "symlinks": {"Applications": "/Applications"},
            # The disk carries the app's icon, in the title bar and on the desktop.
            "icon": os.path.join(ROOT, "App", "AppIcon.icns"),
            "background": os.path.join(HERE, "background.tiff"),
            # Where the window opens, measured from the bottom left of the
            # screen, and its size with the title bar.
            "window_rect": ((220, 260), (INSIDE[0], INSIDE[1] + TITLE_BAR)),
            "default_view": "icon-view",
            "icon_size": 128,
            "text_size": 13,
            "icon_locations": {name: APP_CENTRE, "Applications": APPLICATIONS_CENTRE},
        },
    )


def check(app, output):
    """Mounts the finished image and makes sure of what nobody is there to look at.

    A window that has lost its picture is still a working disk image, and no
    step of a build would notice. Neither would it notice an app whose
    signature did not survive being copied in.
    """
    name = os.path.basename(app)
    with tempfile.TemporaryDirectory() as mount:
        subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount, output],
            check=True,
        )
        try:
            with DSStore.open(os.path.join(mount, ".DS_Store"), "r") as store:
                window = {entry.code: entry.value for entry in store if entry.filename == "."}
                placed = {entry.filename for entry in store if entry.code == b"Iloc"}

            if b"pBBk" in window:
                sys.exit("error: the image records its picture as a bookmark too; recent Finders then show none.")
            icons = window.get(b"icvp")
            if isinstance(icons, (bytes, bytearray)):
                icons = plistlib.loads(icons)
            if not icons or icons.get("backgroundType") != 2 or not icons.get("backgroundImageAlias"):
                sys.exit("error: the image's window has no picture behind it.")
            picture = Alias.from_bytes(icons["backgroundImageAlias"]).target.posix_path
            if not os.path.isfile(os.path.join(mount, picture.lstrip("/"))):
                sys.exit("error: the window's picture, %s, is not in the image." % picture)
            if placed != {name, "Applications"}:
                sys.exit("error: the window places %s, not the app and Applications." % sorted(placed))
            if os.readlink(os.path.join(mount, "Applications")) != "/Applications":
                sys.exit("error: Applications in the image does not lead to /Applications.")
            subprocess.run(
                ["/usr/bin/codesign", "--verify", "--deep", "--strict", os.path.join(mount, name)],
                check=True,
            )
        finally:
            detached = subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", mount])
            if detached.returncode != 0:
                subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", "-force", mount], check=True)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: build.py <Retainer.app> <output.dmg>")
    app, output = sys.argv[1].rstrip("/"), sys.argv[2]
    build(app, output)
    check(app, output)


if __name__ == "__main__":
    main()
