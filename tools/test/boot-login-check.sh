#!/bin/sh
# boot-login-check.sh - boot the server ISO headless and make sure root
# autologin really ends up in a shell. The PAM abort bug prints
# "blueberry login:" and only then dies, so the usual marker test passes on it.
# Here we need the shell prompt on serial, and we also type `id -un` to be sure.
#
# usage: boot-login-check.sh <iso> [serial-log-out]
#   exit 0 = got a root shell. the serial log is kept either way.
set -u
ISO=${1:?usage: boot-login-check.sh <iso> [serial-log]}
SER=${2:-$(mktemp)}
MARK="BBSHELLOK$$"
IN=$(mktemp -u); mkfifo "$IN"
: > "$SER"
ACCEL="-cpu max"; [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL="-enable-kvm -cpu host"
cleanup() { kill "$QPID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$IN"; }
trap cleanup EXIT

# -nographic puts serial on stdin/stdout: guest reads our FIFO, writes to $SER
setsid qemu-system-x86_64 $ACCEL -m 2048 -smp 2 -cdrom "$ISO" \
    -nographic < "$IN" > "$SER" 2>&1 &
QPID=$!
exec 3<>"$IN"   # hold the FIFO open so qemu's stdin never EOFs

deansi() { sed 's/\x1b\[[0-9;:]*m//g' "$SER" 2>/dev/null; }
FAILRE='PAM failure|Critical error - immediate abort|Kernel panic|Attempted to kill init|emergency mode'
PROMPT='\[root@blueberry'          # bash PS1 after a successful login

verdict() { echo "$1"; echo "--- serial tail ---"; tail -20 "$SER" | sed 's/\x1b\[[0-9;:]*m//g'; }

i=0; saw_login=0; fed=0
while [ $i -lt 200 ]; do
    if deansi | grep -qaE "$FAILRE"; then
        echo "FAIL - login/PAM aborted:"; deansi | grep -aoE "$FAILRE" | head -1
        verdict ""; exit 1
    fi
    # the prompt, or our marker plus the id output
    if deansi | grep -qa "$PROMPT" || { deansi | grep -qa "$MARK" && deansi | grep -qa '^root$'; }; then
        echo "PASS - root shell reached (prompt/marker present)"; exit 0
    fi
    if [ $saw_login -eq 0 ] && deansi | grep -qaE 'blueberry login:|automatic login'; then
        saw_login=1
    fi
    # login banner is up: give PAM a moment, then type at it
    if [ $saw_login -eq 1 ] && [ $fed -eq 0 ] && [ $i -ge 6 ]; then
        printf '\n echo %s\n id -un\n' "$MARK" >&3
        fed=1
    fi
    sleep 2; i=$((i+2))
done
echo "FAIL - root shell never reached within timeout"; verdict ""; exit 1
