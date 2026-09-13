# shellcheck shell=bash
# M4, worker cold start: how long from "we need a machine" to "a job is building on it", split
# into the six phases that make up that wait. It decides whether destroying an idle worker is
# viable at all, which is the question docs/poc-plan.md asks it.
#
# Not a build measurement: five of the six phases are timings, and the record schema is open
# for exactly that (docs/design/measurement-harness.md § Results). The sixth is an ordinary
# measure_run, in the guest, through the ssh variant of measure_exec.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

M4_DIR=""
M4_KEEP=0
FORGE_M_GUEST_DIR=/root/measure

# Everything M4 needs that a workload config cannot know: where the image and the firmware
# are, which platform to dial, and who to dial it as. `mix forge.worker.new` prints the last
# three; the devshell exports the firmware.
m4_require() {
  local name
  for name in FORGE_M_WORKER_IMAGE FORGE_M_OVMF_CODE FORGE_M_OVMF_VARS \
    FORGE_M_PLATFORM_URL FORGE_M_WORKER_ID FORGE_M_WORKER_TOKEN FORGE_M_SSH_KEY; do
    [ -n "${!name:-}" ] || fail_add "$name is not set (see docs/measurements.md § M4)"
  done
  [ -r "${FORGE_M_SSH_KEY:-}" ] || fail_add "FORGE_M_SSH_KEY is not readable"
  [ -r "${FORGE_M_WORKER_IMAGE:-}" ] || fail_add "FORGE_M_WORKER_IMAGE is not readable"
  have qemu-system-x86_64 || fail_add "qemu-system-x86_64 is not on PATH"
  have genisoimage || fail_add "genisoimage is not on PATH"
}

# The same machine the provider driver makes, made here: the overlay larger than the image,
# the config disk with the identity on it, UEFI firmware and a per-machine variable store.
# A measurement of a machine built some other way would not transfer.
m4_create_vm() {
  local port=$1 pubkey
  pubkey=$(cat "$FORGE_M_SSH_KEY.pub")

  run mkdir -p "$M4_DIR"
  run qemu-img create -f qcow2 -F qcow2 -b "$FORGE_M_WORKER_IMAGE" \
    "$M4_DIR/disk.qcow2" "${FORGE_M_WORKER_DISK_GB:-40}G" > /dev/null

  # The same file the provider driver writes, on a disk with the same label: the image looks for
  # `forge-config` and reads `worker.env` out of it. See docs/design/worker-tier.md § How a
  # machine learns what it is.
  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    info "would write $M4_DIR/worker.env: the worker id, its token and $FORGE_M_PLATFORM_URL"
  else
    cat > "$M4_DIR/worker.env" << EOF
FORGE_WORKER_ID=$FORGE_M_WORKER_ID
FORGE_WORKER_TOKEN=$FORGE_M_WORKER_TOKEN
FORGE_PLATFORM_URL=$FORGE_M_PLATFORM_URL
FORGE_SSH_KEY=$pubkey
EOF
    chmod 600 "$M4_DIR/worker.env"
  fi

  run genisoimage -quiet -output "$M4_DIR/config.iso" -volid forge-config -joliet -rock \
    "$M4_DIR/worker.env"
  run install -m 600 "$FORGE_M_OVMF_VARS" "$M4_DIR/firmware-vars.fd"

  run qemu-system-x86_64 \
    -name "forge-measure-$FORGE_M_WORKER_ID" \
    -machine accel=kvm:tcg -cpu host \
    -smp "${FORGE_M_WORKER_CPUS:-4}" -m "${FORGE_M_WORKER_MEMORY_MB:-8192}" -display none \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$FORGE_M_OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$M4_DIR/firmware-vars.fd" \
    -drive "file=$M4_DIR/disk.qcow2,if=virtio,format=qcow2" \
    -drive "file=$M4_DIR/config.iso,if=virtio,format=raw,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-net-pci,netdev=net0 \
    -pidfile "$M4_DIR/qemu.pid" -daemonize -serial "file:$M4_DIR/console.log"
}

# Poll until a command in the guest succeeds, or give up loudly. Every phase after create-vm
# ends on one of these, because there is nothing in the guest that can tell the host it is
# ready except the host asking.
m4_wait_for() {
  local what=$1 timeout=$2 cmd=$3 waited=0
  while ! measure_ssh "$cmd" > /dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$timeout" ]; then
      warn "gave up waiting for $what after ${timeout}s"
      return 1
    fi
  done
  return 0
}

# The workload and the harness's in-unit reader, in the guest. Untimed: it is the measurement
# arriving, not part of the cold start a real worker pays for.
m4_prepare_guest() {
  measure_ssh "mkdir -p $FORGE_M_GUEST_DIR" || die "cannot reach the guest"
  measure_scp "$FORGE_M_ROOT/measure/lib/in_unit.sh" "$FORGE_M_GUEST_DIR/in_unit.sh" ||
    die "could not put in_unit.sh in the guest"
}

# The seed, fetched from the platform's store the way the worker fetches it and unpacked into
# a subvolume the way the worker unpacks it, `--no-same-owner` and all. The token is
# short-lived and per-fetch, which is why `mix forge.worker.new` mints one beside the worker's.
m4_seed_fetch() {
  local volume=$1
  measure_ssh "rm -rf $volume && mkdir -p $(dirname "$volume") && btrfs subvolume create $volume" ||
    return 1
  measure_ssh "curl -fsS -o /root/seed.tar.gz '$FORGE_M_PLATFORM_URL/store/$FORGE_M_SEED_KEY?token=$FORGE_M_SEED_TOKEN'" ||
    return 1
  measure_ssh "tar -xzf /root/seed.tar.gz --no-same-owner -C $volume && rm -f /root/seed.tar.gz"
}

# The worktree the last two phases happen in: a snapshot of the seed where there is one, and a
# clone where there is not — which is the same choice `ForgeWorker.Job.Workspace` makes, and
# the reason both are worth timing is that only one of them starts warm.
m4_workspace() {
  local seed=$1 work=$2
  measure_ssh "rm -rf $work" || return 1

  if [ -n "$seed" ]; then
    measure_ssh "btrfs subvolume snapshot $seed $work" || return 1
  else
    m4_send_repo "$work" || return 1
  fi

  measure_ssh "cd $work && git checkout --quiet --detach ${workload_commit}"
}

# The workload's repository, over ssh. It lives on the host's disk and the guest has no route
# to it, so a bare tar of the clone goes over and is cloned again on the other side. Untimed:
# a real worker would have fetched a seed or cloned from the platform.
m4_send_repo() {
  local dest=$1 tarball=$FORGE_M_RUN_DIR/repo.tar
  run tar -cf "$tarball" -C "$(dirname "$M1_REPO")" "$(basename "$M1_REPO")"
  measure_scp "$tarball" /root/repo.tar || return 1
  rm -f "$tarball"
  measure_ssh "cd /root && rm -rf origin && tar -xf repo.tar && git clone --quiet /root/$(basename "$M1_REPO") $dest"
}

m4_teardown() {
  [ "$M4_KEEP" = 1 ] && {
    info "keeping the machine (--keep): $M4_DIR"
    return 0
  }
  section "teardown"
  if [ -r "$M4_DIR/qemu.pid" ]; then
    run kill "$(cat "$M4_DIR/qemu.pid")" 2> /dev/null || true
  fi
  run rm -rf "$M4_DIR"
}

cmd_m4() {
  local port=${FORGE_M_SSH_PORT:-2222} work=$FORGE_M_GUEST_DIR/work

  while [ $# -gt 0 ]; do
    case $1 in
      --keep)
        M4_KEEP=1
        shift
        ;;
      *) die "m4: unknown argument $1" ;;
    esac
  done

  workload_validate workload_repo workload_commit build_dir build_cmd_debug
  m4_require
  fail_report

  m1_paths
  run_dir_init m4
  M4_DIR=$FORGE_M_WORKLOAD_DIR/m4-machine
  run rm -rf "$M4_DIR"

  FORGE_M_SSH=root@127.0.0.1
  FORGE_M_SSH_PORT=$port
  export FORGE_M_SSH FORGE_M_SSH_PORT FORGE_M_SSH_KEY
  trap "m4_teardown" EXIT INT TERM

  section "create-vm"
  phase_begin create-vm
  m4_create_vm "$port"
  phase_end create-vm

  # Named for what it measures rather than for what used to do it: boot, plus the machine
  # reading its own identity off the config disk. cloud-init was this phase until it was
  # replaced (docs/design/worker-tier.md § How a machine learns what it is).
  section "machine-configured"
  phase_begin machine-configured
  if m4_wait_for "the guest to answer ssh" 300 true &&
    m4_wait_for "the machine to read its identity" 300 \
      "systemctl is-active --quiet forge-worker-config.service"; then
    phase_end machine-configured
  else
    phase_end machine-configured timeout
    die "the machine never configured itself (console: $M4_DIR/console.log)"
  fi

  section "worker-connects"
  phase_begin worker-connects
  if m4_wait_for "the worker to join the platform" 300 \
    "journalctl -u forge-worker --no-pager | grep -q 'joined worker:'"; then
    phase_end worker-connects
  else
    phase_end worker-connects timeout
    warn "the worker never joined; is $FORGE_M_PLATFORM_URL reachable from the guest?"
  fi

  m4_prepare_guest

  # The seed carries the checkout, so it comes before the environment is entered and before
  # anything is built in it. The note listed these the other way round, from the draft where a
  # machine fetched its seed before reporting ready; it cannot, and
  # docs/design/worker-tier.md § Volumes and the seed says why.
  local seed="" volume=/var/lib/forge/volumes/${FORGE_M_SEED_KEY:-none}
  section "seed-fetched"
  if [ -n "${FORGE_M_SEED_KEY:-}" ] && [ -n "${FORGE_M_SEED_TOKEN:-}" ]; then
    phase_begin seed-fetched
    if m4_seed_fetch "$volume"; then
      phase_end seed-fetched
      seed=$volume
    else
      phase_end seed-fetched failed
      warn "the seed did not arrive; the phases below are a cold start without one"
    fi
  else
    record "measurement=m4" "phase=seed-fetched" "label=seed-fetched" "status=not_applicable" \
      "reason=no seed is published for this workload, so a first job clones and builds cold"
    info "seed-fetched: not applicable — no seed published"
  fi

  m4_workspace "$seed" "$work" || die "the guest has no worktree to build in"

  # Populating the Nix store is a phase because it is minutes, it happens once per machine,
  # and `nix develop .#<env> --command true` is exactly how the worker triggers it: the entry
  # the first job on a cold machine pays for before it compiles anything.
  section "nix-store-populated"
  if [ -n "${workload_env:-}" ]; then
    phase_begin nix-store-populated
    if measure_ssh "cd $work && nix develop '.#${workload_env}' --command true"; then
      phase_end nix-store-populated
    else
      phase_end nix-store-populated failed
      die "the guest could not enter the workload's environment"
    fi
  else
    record "measurement=m4" "phase=nix-store-populated" "label=nix-store-populated" \
      "status=not_applicable" "reason=the workload has no nix environment to enter"
    info "nix-store-populated: not applicable — no workload_env"
  fi

  section "first-build"
  phase_begin first-build
  measure_run first-build "$work" "$(build_cmd_for debug)"
  measure_record "status=measured" \
    "notes=first build on a machine created for it$([ -n "$seed" ] && echo ', from the seed')"
  phase_end first-build

  section "results"
  cmd_report --run "$FORGE_M_RUN_DIR"
}
