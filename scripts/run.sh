#!/bin/bash
# Builds Retainer.app, launches it, and stays in the foreground until it quits.
#
# This is what the Run button in Conductor calls. Stopping the script (Stop in
# Conductor, Ctrl-C in a shell) quits the app; quitting the app ends the
# script. While the app runs, its log lines are printed here.
#
#   ./scripts/run.sh              build, then run
#   ./scripts/run.sh --no-build   run the existing build/Retainer.app
set -euo pipefail
cd "$(dirname "$0")/.."

# The identifier is from the app's first name and has been kept (see README).
bundle_id="blog.terminal.app"
app="$PWD/build/Retainer.app"

# Prints the pid of every copy of this app that is running, or that macOS
# still counts as running. Copies are recognised by bundle identifier, not
# by name.
#
# Two sources, because each misses something. The process list knows a copy
# only while its bundle is still on disk to read the identifier from.
# LaunchServices goes by identifier whatever has happened to the files, and it
# keeps a copy on its list for a few hundred milliseconds after the process
# has gone. Asked to open the app in that moment it tries to hand the request
# to the dead copy and fails with error -600, so "has it quit" has to mean
# "has LaunchServices let go of it" as well.
running_pids() {
    {
        ps -axww -o pid=,comm= | while read -r pid executable; do
            case "$executable" in
                */Retainer.app/Contents/MacOS/Retainer)
                    bundle="${executable%/Contents/MacOS/Retainer}"
                    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
                    if [ "$id" = "$bundle_id" ]; then echo "$pid"; fi
                    ;;
            esac
        done
        lsappinfo info -only pid "$bundle_id" 2>/dev/null | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p'
    } | sort -un | while read -r pid; do
        # The same binary run with a developer switch (--snapshot and the
        # like) is a tool doing a job, not the app: leave it alone.
        case "$(ps -o args= -p "$pid" 2>/dev/null)" in
            *" --snapshot "* | *" --maps "* | *" --edges "* | *" --motion "* | *" --glass "* | *" --transcribe "* | *" --tidy "* | *" --source-link "*) ;;
            *) echo "$pid" ;;
        esac
    done
    return 0
}

# Asks the app to quit and waits until it has gone, from the process list and
# from LaunchServices. The app treats SIGTERM as a normal quit and writes its
# note index first; anything still alive after three seconds is killed.
quit_app() {
    local pid waited=0
    [ -z "$(running_pids)" ] && return 0
    for pid in $(running_pids); do kill -TERM "$pid" 2>/dev/null || true; done
    while [ -n "$(running_pids)" ] && [ "$waited" -lt 30 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -z "$(running_pids)" ] && return 0
    for pid in $(running_pids); do kill -KILL "$pid" 2>/dev/null || true; done
    waited=0
    while [ -n "$(running_pids)" ] && [ "$waited" -lt 20 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    return 0
}

log_pid=""
open_pid=""
cleanup() {
    trap - EXIT INT TERM HUP
    if [ -n "$log_pid" ]; then kill "$log_pid" 2>/dev/null || true; fi
    quit_app
    if [ -n "$open_pid" ]; then kill "$open_pid" 2>/dev/null || true; fi
}

if [ "${1:-}" != "--no-build" ]; then
    ./scripts/build.sh
fi
if [ ! -d "$app" ]; then
    echo "error: $app does not exist. Run without --no-build." >&2
    exit 1
fi

# Only one copy can run at a time (one global event tap, one note store).
# Replace any copy already running so the build just made is the one that starts.
quit_app

# Builds made while the app was still called Terminal left a bundle under that
# name, with the same identifier. Nothing is running from it any more, and
# two bundles with one identifier leave macOS unsure which of them a
# permission belongs to.
rm -rf "$PWD/build/Terminal.app"

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# The app logs little: errors, and notices such as a rejected tidy pass.
log stream --style compact --predicate "subsystem == \"$bundle_id\"" &
log_pid=$!

echo "Launching $app"
# Through LaunchServices, not by running the binary directly: that is what
# makes macOS attribute privacy permissions to the app itself rather than to
# whatever started this script.
#
# `open -W` returns when the app quits. If it comes back at once with an
# error and nothing is running, macOS did not start the app at all, which it
# can do while it is still tidying up after a previous copy. That is worth
# another try, and worth failing loudly over if it keeps happening.
attempts=5
attempt=1
while true; do
    started=$SECONDS
    open -W "$app" &
    open_pid=$!
    if wait "$open_pid"; then open_status=0; else open_status=$?; fi
    open_pid=""
    if [ "$open_status" -eq 0 ] || [ $((SECONDS - started)) -ge 5 ] || [ -n "$(running_pids)" ]; then
        break
    fi
    if [ "$attempt" -ge "$attempts" ]; then
        echo "error: macOS would not open $app ($attempts attempts; open exited with status $open_status)." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    echo "macOS did not open the app. Trying again ($attempt of $attempts)."
    sleep 1
done

# The app can restart itself: its relaunch button does, and so does macOS's
# "Quit & Reopen" after Screen Recording is granted. Give a restart a moment
# to appear and, if one does, keep following it instead of ending the run.
while true; do
    sleep 1.5
    if [ -z "$(running_pids)" ]; then break; fi
    echo "Retainer restarted itself and is still running."
    while [ -n "$(running_pids)" ]; do sleep 0.5; done
done
echo "Retainer has quit."
