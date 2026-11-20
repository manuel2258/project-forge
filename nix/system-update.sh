#!/usr/bin/env bash
# The privileged half of a permanent machine's self-update (docs/design/worker-tier.md § Updating a
# permanent machine). The worker decides *when*; this does what only root may, one step per
# subcommand, so that each can be run against stand-ins in the gate and none needs a machine:
#
#   system-update.sh space RAW_SIZE
#   system-update.sh fetch REPOSITORY VERSION DIGEST RAW_SHA256 RAW_SIZE
#   system-update.sh install BUILD
#   system-update.sh arm BUILD
#   system-update.sh keep
#   system-update.sh discard
#   system-update.sh fallback [REASON]
#
# **Everything is under one directory only root can enter**, `FORGE_UPDATE_DIR` (0700), which no
# job's user can read or write. The download is checked **in place**, on the very file that is
# then installed: its sha256 against the digest the platform sent, and the raw disk it holds against
# its own size and sha256. Nothing is fetched twice and nothing is read through a path a job could
# replace.
#
# **What the platform sent is never trusted for where to download from**: the repository is checked
# against `FORGE_UPDATE_REPOSITORY`, which is baked into the image. There is no signature (the
# release's owner decided to leave it out for now, `docs/design/worker-tier.md` § Updating a
# permanent machine): what keeps a node to genuine releases is that the image can be fetched only
# from that one repository, by digest, and that the system in it must hold the build named.
#
# A refusal prints `forge-update: <code>: <why>` on stderr as its last line and exits 1; the worker
# turns the last line into the reason it logs and draws. Codes (for a reader of the journal; the
# worker only strips the prefix): `layout`, `repository`, `download`, `checksum`, `esp`, `space`,
# `bad_image`, `install`, `usage`. Each is a failed step with its message; `layout` is also what the
# worker reports as the reason it *cannot* update, before it tries.
set -euo pipefail

dir=${FORGE_UPDATE_DIR:-/var/lib/forge-update}
repository=${FORGE_UPDATE_REPOSITORY:-}
esp=${FORGE_UPDATE_ESP:-/boot}
gcroots=${FORGE_UPDATE_GCROOTS:-/nix/var/nix/gcroots/forge-system}
menu=${FORGE_UPDATE_MENU:-boot-menu.sh}
running_link=${FORGE_UPDATE_RUNNING:-/run/current-system}
layout=${FORGE_UPDATE_LAYOUT:-/etc/forge/layout}
min_free=${FORGE_UPDATE_MIN_FREE:-5368709120}
# The largest raw disk a release may name. The node sends the size, and `space` collects the Nix
# store by up to three times it, which empties every path nothing roots, a project's warm toolchains
# included; a bound is what keeps a hostile node from asking for terabytes. A release's disk is a few
# GiB.
max_raw=${FORGE_UPDATE_MAX_RAW:-34359738368}
fetch_timeout=${FORGE_UPDATE_FETCH_TIMEOUT:-3600}
# Empty on a machine. A stand-in test sets it to put the Nix store's paths under a directory it
# can write, since `/nix/store` is read-only to it (`ForgeWorker.SystemUpdateScriptTest`).
prefix=${FORGE_UPDATE_PREFIX:-}

say() { printf 'forge-update: %s\n' "$1" >&2; }
fail() {
  say "$1: $2"
  exit 1
}

mkdir -p "${dir:?}"
chmod 700 "$dir"
exec 9> "$dir/lock"
flock 9

running() {
  local resolved
  resolved=$(readlink -f "$running_link")
  printf '%s' "${resolved#"$prefix"}"
}
id_of() { basename "$1" | cut -c1-32; }
state_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }

available() { df --output=avail -B1 "$1" | tail -n 1 | tr -d ' '; }

# **Whether it can run at all is decided here too**, not only in the worker: a script invoked by
# anything else must not write a boot entry into a layout that has no room for one.
check_layout() {
  [ "$(cat "$layout" 2> /dev/null || true)" = 2 ] ||
    fail layout "its boot partition holds one system; reinstall it once from the current image"
  # `/boot` is mounted `nofail`, so a machine whose boot partition did not mount still runs; an
  # unmounted `/boot` is then a directory on the root disk, with room to spare, and the boot
  # entries written there are ones no firmware reads.
  mountpoint -q "$esp" ||
    fail esp "the boot partition is not mounted at $esp, so a boot entry written there would never be read"
}

shape() { # shape VALUE REGEX WHAT
  [[ $1 =~ $2 ]] || fail bad_image "$3 is not what a release has: $1"
}

raw_size_shape() { # raw_size_shape VALUE
  # The `{0,15}` is an equivalent mutant: a longer number is refused by the `-le` below all the
  # same (bash's `[` cannot read it as an integer, exits 2, and `||` fires). It only keeps a
  # silly value out of that comparison.
  shape "$1" '^[1-9][0-9]{0,15}$' "the size"
  [ "$1" -le "$max_raw" ] || fail bad_image "the size is $1 bytes, more than the $max_raw a release's disk is"
}

# The size of a file of the mounted image, following its links **inside the image**. A system's
# `kernel` and `initrd` are absolute links into `/nix/store`, which `stat -L` would resolve in the
# running machine's store — where the new system's files are not yet, since this runs before
# `nix copy`.
size_in_image() { # size_in_image MOUNT PATH
  local root=$1 path=$2 target hops=0
  while [ -L "$root$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 10 ] || fail bad_image "too many links under $path"
    target=$(readlink "$root$path")
    case $target in
      /*) path=$target ;;
      *) path=$(dirname "$path")/$target ;;
    esac
  done
  [ -f "$root$path" ] || fail bad_image "$path is not in the image"
  stat -c %s "$root$path"
}

clean() {
  rm -rf "${dir:?}/image.gz" "${dir:?}/image.raw"
}

space() {
  local raw_size=$1 need free
  raw_size_shape "$raw_size"
  # The layer is no larger than the raw disk it compresses, the raw file is the raw disk, and the
  # store paths are at most that again, plus the existing `min-free`.
  need=$((3 * raw_size + min_free))
  free=$(available "$dir")
  if [ "$free" -lt "$need" ]; then
    say "short of room: $free bytes free, $need needed; collecting the Nix store once"
    local before=$free
    nix-store --gc --max-freed "$((need - free))" > /dev/null 2>&1 || true
    free=$(available "$dir")
    # What the worker records as this cleanup's, for the disk report (`ForgeWorker.Update`).
    if [ "$free" -gt "$before" ]; then say "collected $((free - before))"; fi
  fi
  [ "$free" -ge "$need" ] ||
    fail space "not enough room: $free bytes free after collecting the Nix store, $need needed"
}

fetch() {
  local repo=$1 version=$2 digest=$3 raw_sha=$4 raw_size=$5
  check_layout
  [ -n "$repository" ] ||
    fail repository "this machine's image names no repository to update from, so it installs nothing"
  [ "$repo" = "$repository" ] ||
    fail repository "the platform named $repo, and this machine only updates from $repository"
  shape "$version" '^[0-9A-Za-z.+-]+$' "the version"
  shape "$digest" '^sha256:[0-9a-f]{64}$' "the digest"
  shape "$raw_sha" '^[0-9a-f]{64}$' "the checksum"
  raw_size_shape "$raw_size"

  clean
  local host=${repo%%/*} path=${repo#*/} token
  local curl=(curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --max-time "$fetch_timeout")

  token=$("${curl[@]}" "https://$host/token?service=$host&scope=repository:$path:pull" | jq -r '.token // empty') ||
    fail download "could not get a pull token from $host"
  [ -n "$token" ] || fail download "$host gave no pull token"
  local auth=(-H "Authorization: Bearer $token")

  # The layer is fetched by its digest and checked against it, in the place it is then read from.
  "${curl[@]}" "${auth[@]}" -o "$dir/image.gz" "https://$host/v2/$path/blobs/$digest" ||
    fail download "could not download $repo $digest"

  if [ "sha256:$(sha256sum "$dir/image.gz" | cut -d' ' -f1)" != "$digest" ]; then
    clean
    fail checksum "the download is not $digest"
  fi

  if ! gzip -dc < "$dir/image.gz" | dd bs=1M iflag=fullblock conv=sparse of="$dir/image.raw" status=none; then
    clean
    fail bad_image "the download is not a gzip file"
  fi
  rm -f "$dir/image.gz"
  if [ "$(stat -c %s "$dir/image.raw")" != "$raw_size" ] ||
    [ "$(sha256sum "$dir/image.raw" | cut -d' ' -f1)" != "$raw_sha" ]; then
    clean
    fail checksum "the disk image is not the size and checksum the release names"
  fi
  say "downloaded and checked $repo:$version"
}

loop=
cleanup_install() {
  umount "${dir:?}/mnt" > /dev/null 2>&1 || true
  if [ -n "$loop" ]; then losetup -d "$loop" > /dev/null 2>&1 || true; fi
  rmdir "${dir:?}/mnt" > /dev/null 2>&1 || true
  rm -f "${dir:?}/image.raw"
}

install_system() {
  local build=$1 running_system part top id workers worker_hash need free
  local mnt="${dir:?}/mnt"
  check_layout
  shape "$build" '^[a-z0-9]{12}$' "the build"
  [ -f "$dir/image.raw" ] || fail install "there is no downloaded image to install"
  running_system=$(running)

  # What the running system and the fallback hold stays; the system before them goes, so the ESP
  # holds at most the running system, the fallback and the new one while this installs.
  mkdir -p "$gcroots"
  if [ ! -e "$gcroots/current" ]; then ln -sfn "$running_system" "$gcroots/current"; fi
  local keep_ids=("$(id_of "$running_system")")
  if [ -L "$gcroots/fallback" ]; then keep_ids+=("$(id_of "$(readlink -f "$gcroots/fallback")")"); fi
  "$menu" "$esp" prune "${keep_ids[@]}"

  trap cleanup_install EXIT
  mkdir -p "$mnt"
  loop=$(losetup --find --show -P "$dir/image.raw")
  part=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    part=$(lsblk -nrpo NAME,PARTLABEL "$loop" | awk '$2 == "root" { print $1 }')
    if [ -n "$part" ]; then break; fi
    sleep 1
  done
  [ -n "$part" ] || fail bad_image "the disk image has no root partition"
  # Every image is made from the same repart seed, so its btrfs id may be the running root's, and
  # mounting a duplicate is refused or confused before Linux 6.7.
  btrfstune -m "$part" > /dev/null 2>&1 ||
    fail install "could not give the image's root a filesystem id of its own"
  mount -o nosuid,nodev,noexec "$part" "$mnt" || fail install "could not mount the image's root"
  [ -f "$mnt/nix-path-registration" ] && [ -f "$mnt/forge-system" ] ||
    fail bad_image "the image's root is not a forge worker system"
  top=$(cat "$mnt/forge-system")
  shape "$top" '^/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+$' "the system path"
  nix-store --load-db --store "local?root=$mnt" < "$mnt/nix-path-registration" ||
    fail install "could not read the image's store registration"

  # **The target is checked against what is about to be installed**: a node naming a genuine but
  # different release is caught here, before anything is copied or any work paused.
  workers=$(nix-store --store "local?root=$mnt" -qR "$top" |
    grep -E '^/nix/store/[a-z0-9]{32}-forge-worker-[0-9]' || true)
  { [ -n "$workers" ] && [ "$(wc -l <<< "$workers")" -eq 1 ]; } ||
    fail bad_image "the image's system holds no single forge worker"
  worker_hash=$(basename "$workers" | cut -c1-12)
  [ "$worker_hash" = "$build" ] ||
    fail bad_image "the image holds worker build $worker_hash, not the $build the platform named"

  need=$(($(size_in_image "$mnt" "$top/kernel") + $(size_in_image "$mnt" "$top/initrd") + 1048576))
  free=$(available "$esp")
  [ "$free" -ge "$need" ] ||
    fail space "not enough room on the boot partition: $free bytes free, $need needed"

  nix copy --no-check-sigs --from "local?root=$mnt" "$top" ||
    fail install "could not copy the new system into the Nix store"
  id=$(id_of "$top")
  "$menu" "$esp" stage "$id" "$prefix$top" ||
    fail install "could not put the new system on the boot partition"
  ln -sfn "$top" "$gcroots/next"
  printf 'id=%s\nsystem=%s\nbuild=%s\n' "$id" "$top" "$build" > "$dir/staged"
  say "installed $top beside the running system"
}

staged_id=
staged_system=
staged_build=
read_staged() {
  [ -f "$dir/staged" ] || fail install "nothing is installed to arm"
  staged_id=$(state_get "$dir/staged" id)
  staged_system=$(state_get "$dir/staged" system)
  staged_build=$(state_get "$dir/staged" build)
}

# Take a system off the boot partition, and the fallback root with it when that is the system
# the fallback names: updating down to the release that is the fallback stages the very files the
# fallback boots from, and taking them away while the root still names it left the root and the
# boot partition disagreeing.
remove_system() {
  local id=$1
  if [ -L "$gcroots/fallback" ] && [ "$(id_of "$(readlink -f "$gcroots/fallback")")" = "$id" ]; then
    rm -f "${gcroots:?}/fallback"
  fi
  "$menu" "$esp" remove "$id"
}

discard() {
  if [ -f "$dir/staged" ]; then
    read_staged
    remove_system "$staged_id"
    rm -f "$dir/staged"
  fi
  rm -f "${gcroots:?}/next"
  clean
}

arm() {
  local build=$1 previous
  check_layout
  read_staged
  [ "$staged_build" = "$build" ] ||
    fail install "the installed system is build $staged_build, not $build"
  previous=$(running)
  [ -f "$esp/forge/$(id_of "$previous")/meta" ] ||
    fail install "the running system has no boot entry to fall back to"
  "$menu" "$esp" enable "$staged_id" trial
  printf 'id=%s\nsystem=%s\nprevious=%s\nprevious_id=%s\nbuild=%s\n' \
    "$staged_id" "$staged_system" "$previous" "$(id_of "$previous")" "$build" > "$dir/trial"
  rm -f "$dir/staged"
  say "armed $staged_system, to be tried once"
}

keep() {
  [ -f "$dir/trial" ] || fail install "no new system is on trial"
  local id system previous previous_id
  id=$(state_get "$dir/trial" id)
  system=$(state_get "$dir/trial" system)
  previous=$(state_get "$dir/trial" previous)
  previous_id=$(state_get "$dir/trial" previous_id)
  [ "$(running)" = "$system" ] || fail install "the running system is not the one on trial"
  "$menu" "$esp" keep "$id"
  "$menu" "$esp" prune "$id" "$previous_id"
  mkdir -p "$gcroots"
  ln -sfn "$previous" "$gcroots/fallback"
  ln -sfn "$system" "$gcroots/current"
  rm -f "${gcroots:?}/next" "${dir:?}/trial"
  say "kept $system; $previous is the fallback"
}

fallback() {
  local reason=${1:-"the new system was not accepted by the platform within the time allowed"}
  [ -f "$dir/trial" ] || exit 0
  local id system build
  id=$(state_get "$dir/trial" id)
  system=$(state_get "$dir/trial" system)
  build=$(state_get "$dir/trial" build)
  remove_system "$id"
  rm -f "${gcroots:?}/next" "${dir:?}/trial"
  printf 'outcome=fell_back\nbuild=%s\nreason=%s\n' "$build" "$reason" > "$dir/result"
  say "fell back: $reason"
  # Only the new system itself reboots: on the old one this is the boot counting having already
  # done it, and the worker has only to say so.
  if [ "$(running)" = "$system" ]; then systemctl reboot; fi
}

command=${1:-}
if [ $# -gt 0 ]; then shift; fi
case "$command" in
  space) space "$@" ;;
  fetch) fetch "$@" ;;
  install) install_system "$@" ;;
  arm) arm "$@" ;;
  keep) keep ;;
  discard) discard ;;
  fallback) fallback "$@" ;;
  *) fail usage "unknown command: $command" ;;
esac
