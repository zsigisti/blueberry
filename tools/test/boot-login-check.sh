#!/bin/sh
# boot-login-check.sh — boot the server ISO headless and prove the root
# autologin actually reaches a shell (not just prints "blueberry login:").
# The PAM abort regression prints the login prompt and THEN fails, so the
# standard marker test misses it. We capture the serial console and require the
# post-login shell PROMPT to appear, and also drive `id -un` over the (bidi)
# serial line as confirmation.
#
# Usage: boot-login-check.sh <iso> [serial-log-out]
#   exit 0 = root shell reached, 1 = failed. The serial log is preserved.
set -u
ISO=${1:?usage: boot-login-check.sh <iso> [serial-log]}
SER=${2:-$(mktemp)}
MARK="BBSHELLOK$$"
IN=$(mktemp -u); mkfifo "$IN"
: > "$SER"
ACCEL="-cpu max"; [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL="-enable-kvm -cpu host"
cleanup() { kill "$QPID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -f "$IN"; }
trap cleanup EXIT

# -nographic wires the serial port to stdin/stdout bidirectionally: guest reads
# our FIFO, guest console lands in $SER.
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
        echo "FAIL — login/PAM aborted:"; deansi | grep -aoE "$FAILRE" | head -1
        verdict ""; exit 1
    fi
    # Success: the interactive shell prompt, or our driven marker + id output.
    if deansi | grep -qa "$PROMPT" || { deansi | grep -qa "$MARK" && deansi | grep -qa '^root$'; }; then
        echo "PASS — root shell reached (prompt/marker present)"; exit 0
    fi
    if [ $saw_login -eq 0 ] && deansi | grep -qaE 'blueberry login:|automatic login'; then
        saw_login=1
    fi
    # Once the login banner is up, give PAM a moment then drive the shell.
    if [ $saw_login -eq 1 ] && [ $fed -eq 0 ] && [ $i -ge 6 ]; then
        printf '\n echo %s\n id -un\n' "$MARK" >&3
        fed=1
    fi
    sleep 2; i=$((i+2))
done
echo "FAIL — root shell never reached within timeout"; verdict ""; exit 1
