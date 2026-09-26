# Boots the worker image under both firmwares it has to boot under, and fails unless each one
# reaches a login prompt: SeaBIOS, which is QEMU's default and what a Hetzner x86 server runs,
# and OVMF, which is what `Forge.Provider.LocalVm` passes QEMU.
#
# The image was UEFI only until a Hetzner machine sat at "Booting from Hard Disk..." for ever
# and the platform reported it as *made a machine that never connected*. Nothing had booted it
# under BIOS, so nothing could have said so. See docs/design/worker-tier.md § The worker image.
#
# Needs KVM, so it is a flake check rather than a part of `bin/check`:
#
#     nix build .#checks.x86_64-linux.worker-image-boots
#
# No identity is offered, so the machine's config unit fails and says so; the login prompt
# comes regardless and is the thing checked, because it is the proof the firmware found a
# bootloader, the bootloader a kernel and the kernel the root.
{ pkgs, image }:
pkgs.runCommand "forge-worker-image-boots"
{
  nativeBuildInputs = [ pkgs.qemu_kvm pkgs.gnugrep pkgs.coreutils ];
  requiredSystemFeatures = [ "kvm" ];
}
  ''
    # boot NAME EXTRA-QEMU-ARGS... — runs until the serial console shows a login prompt, or
    # fails after three minutes with what the console did say.
    boot() {
      name=$1
      shift
      qemu-img create -q -f qcow2 -F qcow2 -b ${image}/forge-worker.qcow2 "$name.qcow2" 40G
      qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -display none -monitor none \
        -serial "file:$name.log" -nic user,model=virtio-net-pci "$@" &
      qemu=$!

      for _ in $(seq 180); do
        if grep -aq "forge-worker login:" "$name.log"; then
          kill "$qemu"
          wait "$qemu" || true
          echo "$name: reached a login prompt"
          return 0
        fi
        sleep 1
      done

      kill "$qemu" || true
      echo "$name: no login prompt within three minutes; the console said:" >&2
      tail -c 4000 "$name.log" >&2
      return 1
    }

    # The disk as Hetzner presents it: virtio-scsi, larger than the image.
    boot bios \
      -device virtio-scsi-pci,id=scsi \
      -drive file=bios.qcow2,if=none,id=d0,format=qcow2 -device scsi-hd,drive=d0

    # Limine is what booted it, and not something else that happened to be on the disk.
    grep -aq "boot():/limine/kernel" bios.log

    cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    chmod u+w vars.fd
    boot uefi -machine q35 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive file=uefi.qcow2,if=virtio,format=qcow2

    # And under UEFI it is systemd-boot's unified image, as before, and not Limine.
    if grep -aq "boot():/limine/kernel" uefi.log; then
      echo "uefi: booted through Limine, which is the BIOS path" >&2
      exit 1
    fi

    touch $out
  ''
