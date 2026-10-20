#!/usr/bin/env bash
# Runs the GUI Godot editor on a virtual X display (Xvfb) for the host test
# "gui: save in the script editor reaches the running game".
#
# Usage: run-gui.sh <xvfb-run> <godot> <project dir> <log file> <deadline s>
#
# The editor runs in its own session (setsid) with stdin from /dev/null and
# stdout and stderr in <log file>; a game it starts inherits both. On the
# deadline the whole process group is stopped (TERM, then KILL after 5 s).
# Afterwards anything left in the run's session (Xvfb, the editor, a game)
# is killed, so nothing of the run survives it; the same happens when the
# script is interrupted or exits early (trap). An editor a person opened
# is in another session and is never touched. The environment (ZTEST_LOG,
# ZTEST_GUI, the XDG folders) comes from the caller.
#
# Exits 0 when the editor exited with status 0 before the deadline.
set -u

if [ $# -ne 5 ]; then
    echo "usage: run-gui.sh <xvfb-run> <godot> <project dir> <log file> <deadline s>" >&2
    exit 2
fi
xvfb=$1 godot=$2 proj=$3 log=$4 deadline=$5

# OpenGL compatibility rendering works on Xvfb without a GPU (Mesa llvmpipe).
setsid "$xvfb" -a -s "-screen 0 1600x900x24 -nolisten tcp" \
    "$godot" --editor --path "$proj" --rendering-driver opengl3 --rendering-method gl_compatibility \
    < /dev/null > "$log" 2>&1 &
pid=$!
# Interrupted (Ctrl-C on the build, the test killed) or ended early: stop
# everything of this run, Xvfb, the editor and a game it started.
cleanup() {
    kill -TERM -- "-$pid" 2> /dev/null
    sleep 2
    pkill -KILL -s "$pid" 2> /dev/null
}
trap 'cleanup; exit 130' INT TERM HUP
trap cleanup EXIT
start=$(date +%s)
timed_out=0
while kill -0 "$pid" 2> /dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$deadline" ]; then
        timed_out=1
        kill -TERM -- "-$pid" 2> /dev/null
        sleep 5
        kill -KILL -- "-$pid" 2> /dev/null
        break
    fi
    sleep 1
done
wait "$pid"
rc=$?
if pgrep -s "$pid" > /dev/null 2>&1; then
    echo "run-gui.sh: processes of this run left over, killing them"
    pkill -KILL -s "$pid"
fi
trap - EXIT
echo "run-gui.sh: editor exit $rc after $(( $(date +%s) - start )) s (timed out: $timed_out)"
[ "$timed_out" = 0 ] && [ "$rc" = 0 ]
