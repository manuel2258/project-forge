#!/bin/bash
# The first-boot script of the server that puts the release's worker image into a Hetzner
# account (docs/design/provisioning.md § Putting the release's image into an account).
#
# It holds the download address, the checksum and the size, and nothing else: the provider shows
# a server's first-boot script in its console, so no token of the provider's or of forge's and no
# platform address is here. `Forge.Provider.Hetzner` fills in the four quoted values below, each
# already validated (`Forge.WorkerImage`).
#
# **Being powered off is the only success signal, and only the last line of
# `write_and_verify` can produce it.** Any failure ends in `sleep infinity`; the platform sees a
# builder that never powered off and abandons it at the time limit. `poweroff`, `halt` and the
# rest are masked so that nothing else can end the machine.
#
# Not verified on a real machine (the notes say so): the sysrq sequence and the chroot are
# written against the kernel's documented interfaces and the write-and-verify step is tested
# against a file.

REPOSITORY='@REPOSITORY@'
DIGEST='@DIGEST@'
RAW_SHA256='@RAW_SHA256@'
RAW_SIZE='@RAW_SIZE@'

# POSIX sh on purpose: it is also run by dash inside a chroot holding nothing else. Writes the
# gzipped raw image to the device, reads back exactly `size` bytes and compares them with `sha`,
# and only then writes `o` to the trigger. $5 is /proc/sysrq-trigger on a builder.
write_and_verify() {
  gz=$1
  device=$2
  size=$3
  sha=$4
  trigger=$5

  # shellcheck disable=SC2086 # the flags are words
  gzip -dc "$gz" | dd of="$device" bs=4M ${FORGE_BUILDER_DD_FLAGS-oflag=direct} 2> /dev/null
  sync
  # Best effort: a read-back served from the page cache would verify nothing.
  { echo 3 > /proc/sys/vm/drop_caches; } 2> /dev/null

  actual=$(head -c "$size" "$device" | sha256sum | cut -d' ' -f1)
  [ "$actual" = "$sha" ] || return 1

  echo o > "$trigger"
}

stay() {
  echo "forge image builder: $1" >&2
  while true; do sleep 3600; done
}

fetch() {
  host=${REPOSITORY%%/*}
  path=${REPOSITORY#*/}
  mount -o remount,size=3g /dev/shm || return 1
  token=$(curl -fsS "https://$host/token?service=$host&scope=repository:$path:pull" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || return 1
  curl -fsSL --retry 5 -H "Authorization: Bearer $token" -o /dev/shm/image.gz \
    "https://$host/v2/$path/blobs/$DIGEST" || return 1
  echo "${DIGEST#sha256:}  /dev/shm/image.gz" | sha256sum -c - > /dev/null
}

# The tools the write needs, with the libraries `ldd` lists for them, in a tmpfs: the disk under
# the running system is about to be overwritten, and anything not already in memory is gone.
stage() {
  root=/dev/shm/root
  mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys" "$root/proc"
  for tool in dash gzip dd head sha256sum cut sync cat; do
    bin=$(command -v "$tool") || return 1
    cp "$bin" "$root/bin/$tool" || return 1
    for lib in $(ldd "$bin" | grep -o '/[^ ]*'); do
      mkdir -p "$root$(dirname "$lib")"
      cp -n "$lib" "$root$lib"
    done
  done
  mv /dev/shm/image.gz "$root/image.gz"
  mount --bind /dev "$root/dev" && mount -t proc proc "$root/proc"
}

main() {
  systemctl mask poweroff.target halt.target reboot.target ctrl-alt-del.target 2> /dev/null

  fetch || stay "the image could not be downloaded or did not match its checksum"
  stage || stay "the tools could not be staged"

  # The old root read-only, so nothing writes under the write.
  echo u > /proc/sysrq-trigger

  device=${FORGE_BUILDER_DEVICE:-/dev/sda}
  chroot /dev/shm/root /bin/dash -c "$(declare -f write_and_verify); \
    write_and_verify /image.gz '$device' '$RAW_SIZE' '$RAW_SHA256' /proc/sysrq-trigger" ||
    stay "the written disk did not match the checksum"

  # Only reached if the sysrq power-off did not take.
  stay "powering off did not take"
}

if [ "${FORGE_BUILDER_SOURCE_ONLY:-}" != 1 ]; then main; fi
