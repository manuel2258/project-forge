# shellcheck shell=bash
# The copy-on-write layer: volume, seed, snapshots and exclusive bytes. In the self-test the
# whole layer is substituted by plain directories, which is stamped into every record.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

vol_image() {
  echo "$FORGE_M_WORKLOAD_DIR/vol.img"
}

vol_is_mounted() {
  mountpoint -q "$FORGE_M_VOLUME" 2> /dev/null
}

# A loopback image by default, sized by the workload; FORGE_M_BTRFS_MOUNT replaces it with a
# real btrfs mountpoint, which is the better measurement where the operator has one.
vol_up() {
  local img mkfs_opts=()
  mkdir -p "$FORGE_M_VOLUME"

  if [ "$FORGE_M_FAKE" = 1 ]; then
    info "volume: plain directory $FORGE_M_VOLUME (self-test)"
    return 0
  fi

  if [ -n "$FORGE_M_BTRFS_MOUNT" ]; then
    vol_is_mounted || die "FORGE_M_BTRFS_MOUNT=$FORGE_M_BTRFS_MOUNT is not a mountpoint"
    info "volume: operator-supplied $FORGE_M_VOLUME"
    return 0
  fi

  if vol_is_mounted; then
    info "volume: already mounted at $FORGE_M_VOLUME (reusing)"
    return 0
  fi

  img=$(vol_image)
  if [ ! -f "$img" ]; then
    run truncate -s "$m2_volume_size" "$img"
    # Nesting copy-on-write inside copy-on-write is pathological, so the image itself opts
    # out where the containing filesystem is btrfs.
    if [ "$(stat -f -c %T "$FORGE_M_WORKLOAD_DIR" 2> /dev/null || echo unknown)" = btrfs ]; then
      run chattr +C "$img" || warn "chattr +C on the image failed; nested CoW will distort M2"
    fi
    if mkfs.btrfs -O list-all 2>&1 | grep -q squota; then
      mkfs_opts+=(-O squota)
    fi
    run mkfs.btrfs -q "${mkfs_opts[@]}" "$img"
  fi
  # user_subvol_rm_allowed so teardown can delete its own snapshots: without it every run
  # ends in a wall of EPERM that looks like a failure and falls back to walking the tree
  # with rm -rf. The volume is the harness's own, so there is nothing else on it to protect.
  run sudo mount -o loop,noatime,space_cache=v2,user_subvol_rm_allowed "$img" "$FORGE_M_VOLUME"
  run sudo chown "$(id -u):$(id -g)" "$FORGE_M_VOLUME"
  info "volume: loopback $img at $FORGE_M_VOLUME (wall times are indicative, space is not)"
}

vol_down() {
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  [ -n "$FORGE_M_BTRFS_MOUNT" ] && return 0
  vol_is_mounted || return 0
  run sudo umount "$FORGE_M_VOLUME" || warn "umount $FORGE_M_VOLUME failed"
}

subvol_create() {
  local path=$1
  if [ "$FORGE_M_FAKE" = 1 ]; then
    run mkdir -p "$path"
  else
    run btrfs subvolume create "$path" > /dev/null
  fi
}

subvol_delete() {
  local path=$1
  [ -e "$path" ] || return 0
  if [ "$FORGE_M_FAKE" = 1 ]; then
    run rm -rf "$path"
  else
    run btrfs subvolume delete "$path" > /dev/null || run rm -rf "$path"
  fi
}

# A full clone plus the warm build directory, not a git worktree: a worktree's .git is a file
# pointing back at the parent repository, so snapshots of one would share an index and a HEAD
# and their checkouts would collide. Standalone because M4 fetches exactly this artefact.
seed_create() {
  local repo=$1 warm=$2 dest=$3
  subvol_create "$dest"
  run git clone --quiet --no-hardlinks "$repo" "$dest/src"
  # A clone copies only the source's local branches, so the branches M2 checks out have to
  # be carried over explicitly.
  run git -C "$dest/src" fetch --quiet origin '+refs/remotes/origin/*:refs/remotes/origin/*'
  run git -C "$dest/src" checkout --quiet --detach "$workload_commit"
  if [ -d "$warm/$build_dir" ]; then
    run mkdir -p "$dest/src/$build_dir"
    run rsync -aHAX "$warm/$build_dir/" "$dest/src/$build_dir/"
  fi
  fs_sync
}

snapshot_create() {
  local seed=$1 dest=$2
  if [ "$FORGE_M_FAKE" = 1 ]; then
    run cp -a "$seed" "$dest"
  else
    run btrfs subvolume snapshot "$seed" "$dest" > /dev/null
  fi
}

fs_sync() {
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  run sync
  run btrfs filesystem sync "$FORGE_M_VOLUME" > /dev/null 2>&1 || true
}

# Primary reading: no quota subsystem, no rescan, and no write overhead while the builds run.
exclusive_bytes() {
  local path=$1
  if [ "$FORGE_M_FAKE" = 1 ]; then
    du -sb "$path" 2> /dev/null | awk '{print $1}'
    return 0
  fi
  btrfs filesystem du -s --raw "$path" 2> /dev/null |
    awk 'NR > 1 {print $2; exit}'
}

# The cross-check, run after every timed build so its overhead cannot contaminate them. A
# disagreement with the reading above is itself a finding.
qgroup_report() {
  local out=$1
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  run btrfs quota enable "$FORGE_M_VOLUME" > /dev/null 2>&1 || true
  fs_sync
  run btrfs quota rescan -w "$FORGE_M_VOLUME" > /dev/null 2>&1 || true
  btrfs qgroup show -pcre --raw "$FORGE_M_VOLUME" > "$out" 2>&1 || true
  btrfs filesystem usage "$FORGE_M_VOLUME" >> "$out" 2>&1 || true
}

# Stale state from an interrupted run is the classic unexplainable second run, so every
# subcommand refuses to start on one unless --reuse was passed.
vol_check_stale() {
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  [ -n "$FORGE_M_BTRFS_MOUNT" ] && return 0
  if vol_is_mounted; then
    fail_add "a previous run's volume is still mounted at $FORGE_M_VOLUME (bin/measure clean, or --reuse)"
  fi
}
