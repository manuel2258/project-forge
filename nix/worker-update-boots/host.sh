#!/usr/bin/env bash
# The host half of nix/worker-update-boots.nix: boots image A the way a Hetzner x86 server presents
# it (SeaBIOS, virtio-scsi) and under OVMF, gets root through the ssh door the local driver opens
# (FORGE_SSH_KEY on the config disk), and drives `forge-system-update` by hand, step by step, as the
# worker would have, with no platform.
#
#     host.sh <A.qcow2> <B.raw> <B's build> <OVMF directory> <out>
#
# Everything it saw goes to <out>/observations.txt as well as the build log.
set -euo pipefail

image=$1
new_raw=$2
new_build=$3
ovmf=$4
out=$5
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
  for i in $(seq 240); do
    [ "$(logins)" -ge "$n" ] && return 0
    sleep 1
  done
  fail "no login prompt number $n within four minutes (after ${i}s)"
}

ssh_opts=(
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ConnectTimeout=10 -i "$PWD/key"
)

guest() { timeout 900 ssh "${ssh_opts[@]}" -p "$port" root@127.0.0.1 "$@"; }

# No connection is kept across a boot: each is a new sshd.
connect() {
  local i
  for i in $(seq 60); do
    guest true 2> /dev/null && return 0
    sleep 2
  done
  fail "the ssh door did not open"
}

ssh-keygen -q -t ed25519 -N '' -f key
# The bytes `Forge.Provider.MachineConfig.blob/2` writes for a local machine.
cat > worker.env << ENV
FORGE_WORKER_ID=11111111-2222-4333-8444-555555555555
FORGE_WORKER_TOKEN=not-a-real-token
FORGE_PLATFORM_URL=http://10.0.2.2:1
FORGE_MANAGED=1
FORGE_SSH_KEY=$(cat key.pub)
ENV
genisoimage -quiet -output config.iso -volid forge-config -joliet -rock worker.env

qemu=
stop() {
  if [ -n "$qemu" ]; then
    kill "$qemu" 2> /dev/null || true
    wait "$qemu" 2> /dev/null || true
    qemu=
  fi
}
trap stop EXIT

# boot FIRMWARE — a fresh overlay of A, so that every scenario starts from the image as released.
# No -no-reboot: a guest's reboot stays inside the same QEMU, as it does under LocalVm.
boot() {
  local firmware=$1
  stop
  rm -f console.log disk.qcow2 vars.fd
  qemu-img create -q -f qcow2 -F qcow2 -b "$image" disk.qcow2 40G
  if [ "$firmware" = uefi ]; then
    cp "$ovmf/FV/OVMF_VARS.fd" vars.fd
    chmod u+w vars.fd
    qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 -display none -monitor none \
      -serial file:console.log -machine q35 \
      -drive if=pflash,format=raw,readonly=on,file="$ovmf/FV/OVMF_CODE.fd" \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive file=disk.qcow2,if=virtio,format=qcow2 \
      -drive file=config.iso,if=virtio,format=raw,readonly=on \
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=net0 &
  else
    qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 -display none -monitor none \
      -serial file:console.log \
      -device virtio-scsi-pci,id=scsi \
      -drive file=disk.qcow2,if=none,id=d0,format=qcow2 -device scsi-hd,drive=d0 \
      -drive file=config.iso,if=virtio,format=raw,readonly=on \
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=net0 &
  fi
  qemu=$!
  wait_login 1
  connect
  old_build=$(running_worker)
  say "image A runs worker build $old_build; B is $new_build"
  [ "$old_build" != "$new_build" ] || fail "the two releases are the same build"
}

# The script an update runs, found on the machine where the image says it is (it is evaluated there).
# shellcheck disable=SC2016
script='$(systemctl show -p ExecStart --value forge-update-fallback.service | sed -n "s/.*path=\([^ ;]*\) .*/\1/p")'

# The raw disk where the worker's own download leaves it, installed beside the running system,
# armed to be tried once.
install_and_arm() {
  say "-- the new release's raw disk onto the machine"
  guest 'mkdir -p /var/lib/forge-update && chmod 700 /var/lib/forge-update && dd of=/var/lib/forge-update/image.raw bs=1M conv=sparse status=none' < "$new_raw"
  say "-- install"
  guest "$script install $new_build" 2>&1 | tee -a "$report"
  say "-- arm"
  guest "$script arm $new_build" 2>&1 | tee -a "$report"
  guest 'cat /var/lib/forge-update/trial; ls -R /boot/forge /boot/loader/entries' | tee -a "$report"
}

reboot_into_trial() {
  local before
  before=$(logins)
  guest 'systemctl reboot' || true
  wait_login $((before + 1))
  connect
}

# The worker release the running system holds, which is what tells the two systems apart.
running_worker() {
  guest "nix-store -qR /run/current-system | grep -E '^/nix/store/[a-z0-9]{32}-forge-worker-[0-9]' | cut -c12-23"
}

expect_on() {
  local which=$1 want got
  if [ "$which" = new ]; then want=$new_build; else want=$old_build; fi
  got=$(running_worker)
  [ "$got" = "$want" ] || fail "expected the $which system ($want), the machine runs worker build $got"
  say "the machine is on the $which system ($got)"
}

# A trial's entry is counted by systemd-boot; where nothing blesses it, only `keep` may end it.
no_bless() {
  [ "$(guest 'systemctl is-enabled systemd-bless-boot.service 2>&1 || true')" = masked ] ||
    fail "systemd-bless-boot.service is not masked, so it blesses every trial a few seconds after boot"
  say "systemd-bless-boot.service is masked"
}

# until_gone FILE — the worker on the old system settles what the last boot left (a trial it is not
# running, a fallback's result) a few seconds after it starts.
until_gone() {
  local i
  for i in $(seq 60); do
    guest "[ ! -e $1 ]" && return 0
    sleep 2
  done
  fail "$1 is still there"
}

: > "$report"
for firmware in bios uefi; do
  say ""
  say "======== $firmware"
  boot "$firmware"
  guest 'cat /etc/forge/layout; mountpoint /boot' | tee -a "$report"

  # -- the machine's own labels while an image is attached -------------------------------------
  say ""
  say "== by-partlabel while the image is attached"
  guest 'dd of=/root/new.raw bs=1M conv=sparse status=none' < "$new_raw"
  # shellcheck disable=SC2016 # evaluated on the machine
  guest 'set -e
    before=$(readlink -f /dev/disk/by-partlabel/ESP)
    loop=$(losetup --find --show -P /root/new.raw)
    udevadm settle
    for label in ESP root bios-boot; do
      now=$(readlink -f /dev/disk/by-partlabel/$label)
      echo "$label -> $now"
      case $now in /dev/loop*) echo "FAIL: $label follows the loop device"; losetup -d "$loop"; exit 1 ;; esac
    done
    [ "$(readlink -f /dev/disk/by-partlabel/ESP)" = "$before" ]
    losetup -d "$loop"
    rm -f /root/new.raw' 2>&1 | tee -a "$report" || fail "a label followed the loop device"

  # -- a trial that is kept --------------------------------------------------------------------
  say ""
  say "== update, trial, keep ($firmware)"
  install_and_arm
  reboot_into_trial
  expect_on new
  no_bless
  guest "$script keep" 2>&1 | tee -a "$report"
  guest 'ls /boot/loader/entries /boot/forge; ls -l /nix/var/nix/gcroots/forge-system; test ! -e /var/lib/forge-update/trial' | tee -a "$report"
  [ "$(guest 'ls /boot/loader/entries | grep -c "+" || true')" = 0 ] ||
    fail "an entry still carries a counter after keep"
  say "kept; the release link follows the system:"
  guest 'readlink /var/lib/forge/release' | tee -a "$report"
  reboot_into_trial
  expect_on new
  say "and the kept system survives a reboot"

  # -- a trial whose worker is never accepted, ended by the fallback service -------------------
  boot "$firmware"
  say ""
  say "== trial not kept, the fallback service ($firmware)"
  install_and_arm
  reboot_into_trial
  expect_on new
  # The timer is fifteen minutes; the service is what it starts.
  before=$(logins)
  guest 'systemctl start --no-block forge-update-fallback.service' || true
  wait_login $((before + 1))
  connect
  expect_on old
  # The script wrote `result` before it rebooted, and the old system's worker reads it and removes it.
  until_gone /var/lib/forge-update/result
  guest 'ls /boot/loader/entries /boot/forge' | tee -a "$report"
  [ "$(guest 'ls /boot/loader/entries | wc -l; ls /boot/forge | wc -l' | tr '\n' ' ')" = "1 1 " ] ||
    fail "the boot partition still holds more than the old system after the fallback"
  [ "$(guest 'test ! -e /var/lib/forge-update/trial && echo cleared')" = cleared ] ||
    fail "the trial was not cleared"
  say "back on the old system, the new one off the boot partition, its worker having read the result"

  # -- a trial that boots and then panics: UEFI's boot counting alone ends it ------------------
  if [ "$firmware" = uefi ]; then
    boot uefi
    say ""
    say "== trial that panics after boot (uefi)"
    install_and_arm
    reboot_into_trial
    expect_on new
    no_bless
    guest 'ls /boot/loader/entries' | tee -a "$report"
    before=$(logins)
    # `panic=30` on the kernel's command line reboots it half a minute later. The connection goes
    # with the machine.
    timeout 20 ssh "${ssh_opts[@]}" -p "$port" root@127.0.0.1 \
      'echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger' > /dev/null 2>&1 || true
    wait_login $((before + 1))
    connect
    expect_on old
    # Here nothing ran `fallback`: the worker on the old system finds the trial it is not running.
    until_gone /var/lib/forge-update/trial
    say "a trial that booted and then panicked came back on the old system"
  fi
done

say ""
say "all scenarios passed"
stop
cp console.log "$out/console.log" 2> /dev/null || true
