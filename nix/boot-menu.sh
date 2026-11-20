#!/usr/bin/env bash
# The worker image's boot menu, written the same way at build time and at update time
# (docs/design/worker-tier.md § Updating a permanent machine). One script, so the menu the image
# is born with and the menu an update leaves cannot differ.
#
#   boot-menu.sh ESP stage ID TOPLEVEL   copy TOPLEVEL's kernel and initrd to ESP/forge/ID/
#   boot-menu.sh ESP enable ID [trial]   give ID the next generation, and draw the menus
#   boot-menu.sh ESP keep ID             draw the menus with no trial counter
#   boot-menu.sh ESP remove ID           take ID out of the menus and off the ESP
#   boot-menu.sh ESP prune ID...         remove every system not named
#   boot-menu.sh ESP render              draw the menus from what is on the ESP
#   boot-menu.sh ESP generation          the highest generation any system has, or 0
#
# **Each system is `ESP/forge/<id>/{kernel,initrd,meta}`.** systemd-boot reads
# `loader/entries/forge-<id>.conf` and Limine `limine/limine.conf`; both name the same two files,
# so one copy of the kernel serves both firmwares. The menus are drawn from `meta` alone, highest
# **generation** first — a counter this script hands out, not the release's version, which is what
# lets a machine follow its platform down to an older release and still boot it first.
#
# **A trial entry is `forge-<id>+1.conf`.** systemd-boot counts its tries in the file name: it
# renames the file to `+0-1` when it boots it, and a name with no tries left is skipped at the next
# boot, so a new system that never comes up is passed over for the old one. **What ends a trial is
# `keep` and nothing else**: the image masks `systemd-bless-boot.service` (`nix/worker-image.nix`),
# which would otherwise rename the entry to its plain name about six seconds after any boot that
# gets as far as userspace, long before the worker has joined, and a system that then panicked would
# be booted again for ever. Every command that draws the menus deletes every `forge-*.conf` first,
# so it takes the `+0-1` systemd-boot left as readily as the `+1` it was drawn with. Limine has no
# counting at all, so under BIOS the trial's fallback is the worker's own
# (`system-update.sh fallback`).
set -euo pipefail

die() {
  printf 'boot-menu: %s\n' "$1" >&2
  exit 1
}

[ $# -ge 2 ] || die "usage: boot-menu.sh ESP COMMAND [ARGS...]"
esp=$1
command=$2
shift 2
[ -d "$esp" ] || die "no such directory: $esp"

valid_id() { [[ $1 =~ ^[a-z0-9]{8,64}$ ]] || die "not a system id: $1"; }

meta_get() { sed -n "s/^$2=//p" "$esp/forge/$1/meta" | head -n 1; }

meta_set() {
  local file="$esp/forge/$1/meta" tmp
  tmp=$(mktemp "$file.XXXXXX")
  { grep -v "^$2=" "$file" || true; } > "$tmp"
  printf '%s=%s\n' "$2" "$3" >> "$tmp"
  mv "$tmp" "$file"
}

# The ids that have a generation, highest first.
enabled() {
  local dir id generation
  for dir in "$esp"/forge/*/; do
    [ -f "${dir}meta" ] || continue
    id=$(basename "$dir")
    generation=$(meta_get "$id" generation)
    if [ -n "$generation" ]; then printf '%s %s\n' "$generation" "$id"; fi
  done | sort -rn | cut -d' ' -f2
}

render() {
  mkdir -p "$esp/loader/entries" "$esp/limine"
  rm -f "$esp"/loader/entries/forge-*.conf
  printf 'timeout 0\n' > "$esp/loader/loader.conf"

  local limine
  limine=$(mktemp "$esp/limine/limine.conf.XXXXXX")
  printf 'timeout: 0\nserial: yes\n' > "$limine"

  local id generation cmdline name
  while read -r id; do
    [ -n "$id" ] || continue
    generation=$(meta_get "$id" generation)
    cmdline=$(meta_get "$id" cmdline)
    name=forge-$id
    if [ "$(meta_get "$id" trial)" = 1 ]; then name=$name+1; fi
    {
      printf 'title forge worker %s\n' "${id:0:12}"
      printf 'sort-key forge\n'
      printf 'version %08d\n' "$generation"
      printf 'linux /forge/%s/kernel\n' "$id"
      printf 'initrd /forge/%s/initrd\n' "$id"
      printf 'options %s\n' "$cmdline"
    } > "$esp/loader/entries/$name.conf"
    {
      printf '\n/forge-worker %s\n' "${id:0:12}"
      printf '    protocol: linux\n'
      printf '    path: boot():/forge/%s/kernel\n' "$id"
      printf '    module_path: boot():/forge/%s/initrd\n' "$id"
      printf '    cmdline: %s\n' "$cmdline"
    } >> "$limine"
  done < <(enabled)

  mv "$limine" "$esp/limine/limine.conf"
}

case "$command" in
  stage)
    [ $# -eq 2 ] || die "usage: stage ID TOPLEVEL"
    id=$1
    top=$2
    valid_id "$id"
    [ -f "$top/kernel-params" ] || die "$top is not a system: no kernel-params"
    mkdir -p "$esp/forge/$id"
    # `cp -L`: the toplevel's `kernel` and `initrd` are links into the store.
    cp -L "$top/kernel" "$esp/forge/$id/kernel.new"
    cp -L "$top/initrd" "$esp/forge/$id/initrd.new"
    mv "$esp/forge/$id/kernel.new" "$esp/forge/$id/kernel"
    mv "$esp/forge/$id/initrd.new" "$esp/forge/$id/initrd"
    printf 'cmdline=init=%s/init %s\n' "$top" "$(cat "$top/kernel-params")" > "$esp/forge/$id/meta"
    ;;
  enable)
    id=${1:?usage: enable ID [trial]}
    valid_id "$id"
    [ -f "$esp/forge/$id/meta" ] || die "$id is not staged"
    top=$("$0" "$esp" generation)
    meta_set "$id" generation "$((top + 1))"
    if [ "${2:-}" = trial ]; then meta_set "$id" trial 1; fi
    render
    ;;
  keep)
    id=${1:?usage: keep ID}
    valid_id "$id"
    [ -f "$esp/forge/$id/meta" ] || die "$id is not on the ESP"
    meta_set "$id" trial 0
    render
    ;;
  remove)
    id=${1:?usage: remove ID}
    valid_id "$id"
    rm -rf "${esp:?}/forge/$id"
    render
    ;;
  prune)
    for dir in "$esp"/forge/*/; do
      [ -d "$dir" ] || continue
      id=$(basename "$dir")
      keep=false
      for wanted in "$@"; do
        if [ "$wanted" = "$id" ]; then keep=true; fi
      done
      if [ "$keep" = false ]; then rm -rf "${esp:?}/forge/$id"; fi
    done
    render
    ;;
  render) render ;;
  generation)
    highest=0
    while read -r id; do
      [ -n "$id" ] || continue
      generation=$(meta_get "$id" generation)
      if [ "$generation" -gt "$highest" ]; then highest=$generation; fi
    done < <(enabled)
    printf '%s\n' "$highest"
    ;;
  *) die "unknown command: $command" ;;
esac
