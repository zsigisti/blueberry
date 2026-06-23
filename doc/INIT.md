# Init Systems — systemd (default) and runit

## 1. Overview

Blueberry runs **systemd** as PID 1 by default (`INIT=systemd`) on both editions
— journald, logind (the seats/sessions the GUI needs), networkd/resolved/
timesyncd, and OpenSSH. The integration layer is in `src/systemd/`;
`make server-iso` builds a live systemd Server ISO.

A minimal **runit** build remains available with `INIT=runit` for RAM-first /
embedded use; the rest of this document describes that scheme. runit is a UNIX
init scheme with service supervision by Gerrit Pape — ~35 KB, dependency-free,
the default init of Void Linux since 2008.

The entire init system is three shell scripts and one binary (`runsvdir`).
There is no binary logging format, no socket activation, no unit file parser.

---

## 2. The Three Stages

runit divides system lifetime into three stages, each controlled by a script
in `/etc/runit/`.

### Stage 1 — `/etc/runit/1`

Runs **once** at boot as PID 1's first child. Must exit successfully for
the system to continue booting. Responsible for:

- Mounting `/proc`, `/sys`, `/dev`, `/run`
- Seeding the RNG from saved state (`/var/lib/random-seed`)
- Setting the hostname from `/etc/hostname`
- Running `mdev -s` to populate `/dev` from `/sys`
- Running `hwclock -s` to set the system clock
- Running `fsck -A` for filesystems in `/etc/fstab`
- Remounting `/` read-write
- Mounting remaining `/etc/fstab` entries
- Loading kernel modules from `/etc/modules`
- Applying `sysctl` settings from `/etc/sysctl.d/*.conf`

Blueberry's stage 1 is at `src/init/1`.

### Stage 2 — `/etc/runit/2`

Runs after stage 1 exits 0. This script **does not exit under normal
operation** — runit waits for it. Responsible for:

- Symlinking enabled services from `/etc/sv/enabled/` to `/var/service/`
- Running `runsvdir /var/service`

`runsvdir` is the supervision daemon. It scans `/var/service/` and starts
a `runsv` process for each entry.

### Stage 3 — `/etc/runit/3`

Called when runit receives a shutdown signal. Responsible for:

- Saving RNG state to `/var/lib/random-seed`
- Sending `SIGTERM` to all processes, then `SIGKILL`
- Running `sync`
- Unmounting all filesystems
- Executing `halt -f`, `reboot -f`, or `poweroff -f`

---

## 3. Service Directories

Each service is a directory in `/etc/sv/<name>/`. It contains:

```
/etc/sv/<name>/
  run          Mandatory. Executable. Must exec the service process.
  finish       Optional. Executable. Called when 'run' exits.
  down         Optional. If present, service does not auto-start.
  log/         Optional. If present, stdout of 'run' is piped to log/run.
    log/run    Executable. Typically 'exec svlogd -tt /var/log/<name>'
```

The `run` script is executed by `runsv`. It **must** exec (not fork) the
service process so that runsv can monitor it directly. A service that forks
into the background will appear to crash immediately.

### 3.1  Example: sshd

```sh
#!/bin/sh
# /etc/sv/sshd/run
exec /usr/sbin/sshd -D -e 2>&1
```

`-D` prevents sshd from daemonizing. `-e` sends errors to stderr (which
`svlogd` captures if a log/ service is present).

### 3.2  Example: a custom service with logging

```sh
# /etc/sv/myapp/run
#!/bin/sh
exec chpst -u myapp:myapp /usr/bin/myapp --config /etc/myapp/config.toml
```

```sh
# /etc/sv/myapp/log/run
#!/bin/sh
exec svlogd -tt /var/log/myapp
```

`svlogd` rotates logs automatically. The `-tt` flag prepends ISO 8601
timestamps to each line.

### 3.3  The `finish` script

Called whenever `run` exits, regardless of exit code. Receives two arguments:
`$1` = exit code of `run`, `$2` = signal that killed it (or -1 if not killed).

```sh
# /etc/sv/myapp/finish
#!/bin/sh
echo "myapp exited with code $1"
# Remove a PID file, send a notification, etc.
```

---

## 4. Activating and Deactivating Services

Services are activated by symlinking from `/etc/sv/enabled/` (or directly
into `/var/service/`):

```sh
# Enable a service
ln -s /etc/sv/sshd /var/service/sshd

# Disable a service (remove symlink)
rm /var/service/sshd

# Enable at boot (via the enabled/ directory)
ln -s /etc/sv/sshd /etc/sv/enabled/sshd
```

Stage 2 automatically symlinks everything in `/etc/sv/enabled/` into
`/var/service/` on each boot.

---

## 5. The `sv` Command

`sv` is the service management tool. It communicates with `runsv` over a
Unix socket in the service directory.

```sh
sv status <service>     # print status (up/down, PID, uptime)
sv up <service>         # start service (if not running)
sv down <service>       # stop service (send TERM, then KILL after 7s)
sv restart <service>    # stop then start
sv reload <service>     # send HUP (service must handle it)
sv once <service>       # start once; do not restart if it exits
sv hup <service>        # send HUP
sv term <service>       # send TERM
sv kill <service>       # send KILL
sv pause <service>      # send STOP (suspend)
sv cont <service>       # send CONT (resume)

sv status /var/service/*   # status of all running services
```

---

## 6. Logging with svlogd

`svlogd` is runit's logging daemon. It reads lines from stdin and writes them
to a log directory with automatic rotation.

```sh
# Typical log/run script:
#!/bin/sh
exec svlogd -tt /var/log/myapp
```

Log files in `/var/log/myapp/`:
```
current             # active log file (being written)
@<timestamp>.<size> # rotated old log files
lock                # lock file (prevents double-start)
```

Configuration via `/var/log/myapp/config`:
```
s1000000   # rotate when current exceeds 1 MB
n10        # keep at most 10 rotated files
t          # prepend timestamps
```

---

## 7. Shutdown and Reboot

Blueberry ships with busybox, which provides `halt`, `reboot`, and `poweroff`
that communicate with PID 1 (runit):

```sh
reboot            # reboot
poweroff          # power off
halt              # halt the CPU

# Or via runit directly:
runit-init 6      # reboot
runit-init 0      # poweroff
runit-init 1      # halt
```

---

## 8. Alternative Init Systems

runit is used only on the optional disk-boot path; the live CLI runs straight
from the initramfs and needs no init system at all. If you want a different
init on a disk install, build it from source into the rootfs (add it under
`src/`, link it from `make world`) and repoint `/sbin/init` at it:

- **s6 + s6-rc** — `ln -sf /usr/bin/s6-linux-init-bin /sbin/init`; convert the
  runit service dirs with `s6-rc-compile`.
- **OpenRC** — `ln -sf /sbin/openrc-init /sbin/init`; services live in
  `/etc/init.d/`, runlevels replace stage 2.
- **dinit** — `ln -sf /sbin/dinit /sbin/init`; services in `/etc/dinit.d/`.

Boot the chosen init by passing `init=/sbin/init` (or any path) on the kernel
command line alongside `root=`. systemd is not supported.

---

## 9. Writing a New Service

1. Create the service directory:
   ```sh
   mkdir /etc/sv/myapp
   ```

2. Write `run`:
   ```sh
   cat > /etc/sv/myapp/run <<'EOF'
   #!/bin/sh
   exec /usr/bin/myapp --foreground
   EOF
   chmod +x /etc/sv/myapp/run
   ```

3. Optionally, set up logging:
   ```sh
   mkdir /etc/sv/myapp/log /var/log/myapp
   cat > /etc/sv/myapp/log/run <<'EOF'
   #!/bin/sh
   exec svlogd -tt /var/log/myapp
   EOF
   chmod +x /etc/sv/myapp/log/run
   ```

4. Enable it:
   ```sh
   ln -s /etc/sv/myapp /var/service/myapp
   ```

5. Check status:
   ```sh
   sv status myapp
   ```

---

## 10. Debugging Init Issues

### Service won't start

```sh
sv status myapp           # is it up or down?
cat /etc/sv/myapp/supervise/status  # raw status bytes
ls -la /var/service/      # is the symlink correct?
sh -x /etc/sv/myapp/run   # test the run script manually
```

### System hangs in stage 1

Stage 1 runs as PID 1's child. If it hangs, the system will not proceed to
stage 2. To debug:

1. Boot with `rescue` on the kernel command line — this drops into
   the initramfs shell before switching root.
2. Boot with `debug` — adds `set -x` to the initramfs init script.
3. Connect a serial console and watch the stage 1 output.

### Service keeps restarting

If `run` exits immediately, runsv waits 1 second before restarting it.
This prevents a crash loop from consuming 100% CPU. Check:

```sh
# See if it's cycling
sv status myapp   # watch the "uptime" counter

# Look at logs
tail /var/log/myapp/current

# Run manually with trace
sh -x /etc/sv/myapp/run
```
