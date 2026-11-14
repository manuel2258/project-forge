#!/bin/bash
# The first-boot script of the server that puts the release's worker image into a Hetzner
# account (docs/design/provisioning.md § Putting the release's image into an account).
#
# It holds the download address, the checksum and the size, and nothing else: the provider shows
# a server's first-boot script in its console, so no token of the provider's or of forge's and no
# platform address is here. `Forge.Provider.Hetzner` fills in the four quoted values below, each
# already validated (`Forge.WorkerImage`).
#
# **Being powered off is the only success signal**, and the writer's own power-off is the last line
# of `write_and_verify`, after the comparison. Any failure of the script's ends in a wait that never
# returns; the platform sees a builder that never powered off and abandons it at the time limit.
# `halt`, `reboot` and the rest are masked so that nothing else can end the machine, and `poweroff`
# is unmasked only once the image and the program that writes it are staged. What this cannot
# prevent is systemd failing to pivot into the staged root or to execute the writer: it then powers
# off on its own with nothing written (docs/design/provisioning.md says which of these is guarded).
#
# **The disk is written with nothing mounted from it.** Writing it under the running system — its
# root remounted read-only by sysrq — failed on every real builder: the old filesystem stayed
# mounted and in use, kept writing into the first gigabytes after `dd` was done, and the read-back
# never matched. So the write happens at power-off instead, through systemd's own hook for it
# (bootup(7), "/run/initramfs/shutdown"): systemd stops every service, unmounts what it can,
# pivots into /run/initramfs with the old root at /oldroot and executes our `shutdown` there as
# PID 1, which unmounts /oldroot and only then writes.

REPOSITORY='@REPOSITORY@'
DIGEST='@DIGEST@'
RAW_SHA256='@RAW_SHA256@'
RAW_SIZE='@RAW_SIZE@'

# Where systemd-shutdown looks for the program to hand PID 1 to. On /run, which systemd never
# unmounts; a tmpfs of its own here would be unmounted before the hand-over.
STAGE=/run/initramfs

# POSIX sh on purpose: it is also run by dash as PID 1 in the staged root, holding nothing else.
# Writes the gzipped raw image to the device, reads back exactly `size` bytes and compares them
# with `sha`, and only then writes `o` to the trigger. $5 is /proc/sysrq-trigger on a builder.
#
# `iflag=fullblock` because a pipe hands `dd` 8–32 KiB at a time, and with `oflag=direct` every
# short read was its own synchronous write. Removing it is an equivalent mutant under test: the
# bytes written are the same and only their number of writes differs, which no file shows.
write_and_verify() {
  gz=$1
  device=$2
  size=$3
  sha=$4
  trigger=$5

  # shellcheck disable=SC2086 # the flags are words
  gzip -dc "$gz" | dd of="$device" bs=4M iflag=fullblock ${FORGE_BUILDER_DD_FLAGS-oflag=direct} 2> /dev/null
  sync
  # Best effort: a read-back served from the page cache would verify nothing.
  { echo 3 > /proc/sys/vm/drop_caches; } 2> /dev/null

  actual=$(head -c "$size" "$device" | sha256sum | cut -d' ' -f1)
  [ "$actual" = "$sha" ] || return 1

  echo o > "$trigger"
}

# To the console the provider shows, which is the only place a builder's words can be read.
say() {
  for tty in /dev/console /dev/tty0; do
    echo "forge image builder: $1" > "$tty"
  done 2> /dev/null
}

stay() {
  say "$1"
  while true; do sleep 3600; done
}

fetch() {
  host=${REPOSITORY%%/*}
  path=${REPOSITORY#*/}
  # `exec` because Debian mounts /run noexec, and on a noexec mount access(X_OK) fails even for
  # root: systemd-shutdown then skips the hand-over without a word and simply powers off, which is
  # the success signal with nothing written. Seen on a real builder.
  mount -o remount,exec,size=3g /run || return 1
  mkdir -p "$STAGE" || return 1
  token=$(curl -fsS "https://$host/token?service=$host&scope=repository:$path:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || return 1
  # Every error retried, not only the transient ones: a dropped HTTP/2 stream (curl's 92) is not
  # transient to curl.
  curl -fsSL --retry 5 --retry-all-errors -H "Authorization: Bearer $token" -o "$STAGE/image.gz" \
    "https://$host/v2/$path/blobs/$DIGEST" || return 1
  echo "${DIGEST#sha256:}  $STAGE/image.gz" | sha256sum -c - > /dev/null
}

# The tools the write needs, with the libraries `ldd` lists for them, and the program systemd hands
# PID 1 to: everything it runs must be in memory, because the disk is about to be overwritten.
stage() {
  device=$1
  mkdir -p "$STAGE/bin" "$STAGE/dev" "$STAGE/proc" "$STAGE/sys" "$STAGE/oldroot" || return 1
  for tool in dash gzip dd head sha256sum cut sync cat sleep mount umount; do
    bin=$(command -v "$tool") || return 1
    cp "$bin" "$STAGE/bin/$tool" || return 1
    # Checked, each of them: a writer whose loader or library is missing fails at execve, and
    # systemd-shutdown then powers off with nothing written, as it does when it cannot run it.
    for lib in $(ldd "$bin" | grep -o '/[^ ]*'); do
      mkdir -p "$STAGE$(dirname "$lib")" || return 1
      [ -e "$STAGE$lib" ] || cp "$lib" "$STAGE$lib" || return 1
    done
  done

  {
    echo '#!/bin/dash'
    echo 'PATH=/bin'
    declare -f write_and_verify say stay
    echo '[ -e /proc/self/mounts ] || mount -t proc proc /proc || stay "proc could not be mounted"'
    echo "[ -b '$device' ] || mount -t devtmpfs devtmpfs /dev"
    # `dd` given a path that is not a block device makes a file in memory, reads that back, finds the
    # checksum and powers off with the disk untouched: so no device, no write.
    echo "[ -b '$device' ] || stay '$device is not a block device'"
    # Not lazily: a detached filesystem that something still holds would go on writing, which is
    # the failure this whole hand-over exists to avoid. Every process is gone by now.
    echo 'umount -R /oldroot || stay "the old root could not be unmounted"'
    echo "write_and_verify /image.gz '$device' '$RAW_SIZE' '$RAW_SHA256' /proc/sysrq-trigger ||"
    echo '  stay "the written disk did not match the checksum"'
    # The sysrq power-off is carried out by the kernel a moment later, so this waits before saying
    # it did not take. PID 1 must never exit.
    echo 'sleep 60'
    echo 'stay "powering off did not take"'
  } > "$STAGE/shutdown" || return 1
  chmod 755 "$STAGE/shutdown"
}

main() {
  systemctl mask poweroff.target halt.target reboot.target ctrl-alt-del.target 2> /dev/null

  fetch || stay "the image could not be downloaded or did not match its checksum"
  stage "${FORGE_BUILDER_DEVICE:-/dev/sda}" || stay "the tools could not be staged"

  # systemd-shutdown asks exactly this — access(X_OK) — and when the answer is no it powers off
  # without writing anything, which the platform would take for a finished build. `[ -x ]` is the
  # same call, so the builder stays on instead.
  [ -x "$STAGE/shutdown" ] || stay "systemd could not execute the staged writer"

  say "staged; powering off to write the disk"
  systemctl unmask poweroff.target 2> /dev/null
  systemctl --no-block poweroff || stay "the power-off that writes the disk could not be started"
}

if [ "${FORGE_BUILDER_SOURCE_ONLY:-}" != 1 ]; then main; fi
