#!/usr/bin/env python3
"""Inspect or repair only Runpod Desktop's macOS widget registrations.

No app bundles, widget placements, preferences, or credentials are deleted.
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


APP_ID = "local.abteen.RunpodDesktop"
WIDGET_ID = APP_ID + ".Widget"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def registered_apps():
    """Read exact app IDs; names and arbitrary substring matches are insufficient."""
    dump = run(LSREGISTER, "-dump").stdout
    paths = set()
    for record in re.split(r"\n-{20,}\n", dump):
        identifier = re.search(r"^identifier:\s+(.+?)\s*$", record, re.MULTILINE)
        path = re.search(r"^path:\s+(.+?) \(0x[0-9a-fA-F]+\)\s*$", record, re.MULTILINE)
        if identifier and identifier.group(1) == APP_ID and path:
            paths.add(path.group(1))
    return sorted(paths)


def load_info(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as source:
        return plistlib.load(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path,
                        default=Path.home() / "Applications/Runpod Desktop.app")
    parser.add_argument("--repair", action="store_true",
                        help="Unregister other Runpod copies and register the selected installed app.")
    parser.add_argument("--restart-host", action="store_true",
                        help="With --repair, also restart the current user's widget host.")
    args = parser.parse_args()
    if args.restart_host and not args.repair:
        parser.error("--restart-host requires --repair")

    app = args.app.expanduser().resolve()
    widget = app / "Contents/PlugIns/RunpodWidget.appex"
    try:
        app_info, widget_info = load_info(app), load_info(widget)
    except (OSError, plistlib.InvalidFileException) as error:
        sys.exit(f"Cannot read the installed app and widget: {error}")
    if app_info.get("CFBundleIdentifier") != APP_ID or widget_info.get("CFBundleIdentifier") != WIDGET_ID:
        sys.exit("This is not the expected Runpod Desktop app and widget bundle.")
    if app_info.get("CFBundleVersion") != widget_info.get("CFBundleVersion"):
        sys.exit("App and widget build numbers differ. Rebuild them together with build.sh.")
    verification = run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app), check=False)
    if verification.returncode:
        sys.exit(f"App signature verification failed. Rebuild with build.sh.\n{verification.stderr.strip()}")

    paths = registered_apps()
    duplicates = [path for path in paths if Path(path).resolve() != app]
    print(f"App: {app}")
    print(f"App and widget build: {app_info['CFBundleVersion']} (signatures valid)")
    for path in paths:
        print(f"Registered copy: {path}")
    if duplicates:
        print("Other registered copies can make macOS load the wrong app or widget build.")

    if args.repair:
        # An extension process from the previous binary can survive the containing app.
        run("/usr/bin/pkill", "-u", str(os.getuid()), "-x", "RunpodWidget", check=False)
        # Remove the old PlugInKit identity as well as its containing app's
        # Launch Services record before registering the replacement binary.
        run("/usr/bin/pluginkit", "-r", str(widget), check=False)
        for path in paths:
            run(LSREGISTER, "-u", path, check=False)
        run(LSREGISTER, "-f", str(app))
        run("/usr/bin/pluginkit", "-a", str(widget))
        run("/usr/bin/pluginkit", "-e", "use", "-i", WIDGET_ID)
        if args.restart_host:
            run("/usr/bin/pkill", "-u", str(os.getuid()), "-x", "chronod", check=False)
        print("Registered the installed widget. Other app copies were left on disk.")
        print("Open Runpod Desktop, then search for it in Edit Widgets.")
        print("Remove any old blank Runpod widget and add it again; its old extension ID may have changed.")
    elif not paths:
        print("The app is not registered with Launch Services. Run this command with --repair.")

    plugins = run("/usr/bin/pluginkit", "-m", "-v", "-A", "-i", WIDGET_ID, check=False)
    print(plugins.stdout.strip() or "Widget extension is not registered. Run this command with --repair.")
    if not args.repair:
        print("To repair registration: python3 RunpodDesktop/widget-doctor.py --repair --restart-host")


if __name__ == "__main__":
    main()
