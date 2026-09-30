#!/usr/bin/env bash
# The host half of nix/worker-health.nix: boots the worker image the way a Hetzner x86 server
# presents it (SeaBIOS, virtio-scsi) with the local driver's config disk, gets root through the
# ssh door `Forge.Provider.LocalVm` opens (FORGE_SSH_KEY on the disk, a forward to port 22),
# runs guest.sh's items in the one order that works — the wedge last, since nothing comes back
# from it but a reboot — and then reboots the wedged machine and checks it is the same one.
#
#     host.sh <image.qcow2> <this directory> <out>
#
# Everything the guest printed goes to <out>/observations.txt as well as the build log.
set -euo pipefail

image=$1
dir=$2
out=$3
port=2222
mkdir -p "$out"
report=$out/observations.txt
export HOME=$PWD

say() { printf '%s\n' "$*" | tee -a "$report"; }

fail() {
  say "FAIL: $*"
  echo "the console's last 4000 bytes:" >&2
  tail -c 4000 console.log >&2 || true
  exit 1
}

logins() {
  if [ -e console.log ]; then grep -ac "forge-worker login:" console.log || true; else echo 0; fi
}

# wait_login N — until the console has shown its Nth login prompt.
wait_login() {
  local n=$1 i
  for i in $(seq 180); do
    [ "$(logins)" -ge "$n" ] && return 0
    sleep 1
  done
  fail "no login prompt number $n within three minutes (after ${i}s)"
}

# One connection for the whole boot, opened before anything can wedge: a new ssh login needs
# PID 1 (through logind), and with PID 1 wedged a new one hangs. What rides on this one does not.
ssh_opts=(
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath="$PWD/cm" -o ControlPersist=yes
  -i "$PWD/key"
)

# Every call has a deadline: a unit that never ends would otherwise hold the build, silent, for
# ever. The longest item, the health wait, is four minutes.
guest() { timeout 600 ssh "${ssh_opts[@]}" -p "$port" root@127.0.0.1 "$@"; }

connect() {
  ssh "${ssh_opts[@]}" -O exit -p "$port" root@127.0.0.1 2> /dev/null || true
  rm -f cm
  local i
  for i in $(seq 60); do
    guest true 2> /dev/null && return 0
    sleep 2
  done
  fail "the ssh door did not open"
}

# item NAME — one of guest.sh's items, its output kept, its failure the check's.
item() {
  say ""
  say "== $1"
  local status=0
  guest "/root/worker-health/guest.sh $1" 2>&1 | tee -a "$report" || status=$?
  [ "$status" = 0 ] || fail "item $1"
}

ssh-keygen -q -t ed25519 -N '' -f key
# The bytes `Forge.Provider.MachineConfig.blob/2` writes for a local machine.
cat > worker.env << EOF
FORGE_WORKER_ID=11111111-2222-4333-8444-555555555555
FORGE_WORKER_TOKEN=not-a-real-token
FORGE_PLATFORM_URL=http://10.0.2.2:1
FORGE_MANAGED=1
FORGE_SSH_KEY=$(cat key.pub)
EOF
genisoimage -quiet -output config.iso -volid forge-config -joliet -rock worker.env
qemu-img create -q -f qcow2 -F qcow2 -b "$image" disk.qcow2 40G

# No -no-reboot: a guest's reboot stays inside the same QEMU, as it does under LocalVm.
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 -display none -monitor none \
  -serial file:console.log \
  -device virtio-scsi-pci,id=scsi \
  -drive file=disk.qcow2,if=none,id=d0,format=qcow2 -device scsi-hd,drive=d0 \
  -drive file=config.iso,if=virtio,format=raw,readonly=on \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=net0 &
qemu=$!
trap 'kill "$qemu" 2> /dev/null || true' EXIT

wait_login 1
connect
timeout 120 scp "${ssh_opts[@]}" -q -r -P "$port" "$dir" root@127.0.0.1:/root/worker-health
guest 'chmod -R u+w,a+rX /root/worker-health && chmod +x /root/worker-health/guest.sh'

item identity
first_boot=$(grep '^boot ' "$report" | tail -1)
first_env=$(grep '^env-sha256 ' "$report" | tail -1)

item oom-child
item oom-main
item readings
item forgery
item wedge
item health

say ""
say "== reboot, with PID 1 wedged"
before=$(logins)
started=$(date +%s)
# The connection goes with the machine, so this never returns on its own: it is left to its
# timeout in the background, and the console is what is timed.
timeout 30 ssh "${ssh_opts[@]}" -p "$port" root@127.0.0.1 '/root/worker-health/guest.sh reboot' \
  > reboot.out 2>&1 &
asked=$!
wait_login $((before + 1))
say "a login prompt again $(($(date +%s) - started))s after the reboot was asked for, in the same QEMU"
wait "$asked" || true
say "ForgeWorker.Health.reboot/0 returned: $(cat reboot.out)"
grep -aq 'reboot: Restarting system' console.log || fail "the kernel never said it was restarting"

connect
item identity
second_boot=$(grep '^boot ' "$report" | tail -1)
second_env=$(grep '^env-sha256 ' "$report" | tail -1)
[ "$first_boot" != "$second_boot" ] || fail "the boot id did not change: the machine did not reboot"
[ "$first_env" = "$second_env" ] || fail "the identity differs after the reboot"
say "the same identity, byte for byte, written again on the new boot"

cp console.log "$out/console.log"
