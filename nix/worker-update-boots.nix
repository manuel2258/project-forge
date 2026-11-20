# A permanent machine updating itself from one release to another, on the real image, under the
# firmwares a machine boots under: what `nix/system-update.sh` and `nix/boot-menu.sh` do on a real
# kernel, a real loop device and a real bootloader, which the suite can only run against stand-ins
# (docs/design/worker-tier.md § Updating a permanent machine).
#
# Image A is the release as it stands, B the same source under another version, so that its worker
# is another build. B's raw disk is put where the machine's own download would leave it, and the
# script's `install` and `arm` run on A, then the machine reboots:
#
#   - BIOS and UEFI: the machine comes up on B, `keep` ends the trial, and B survives a reboot;
#   - BIOS and UEFI: a trial whose worker is never accepted goes back to A through the fallback
#     service, the new system's entry and files are gone, and A's worker reads the result;
#   - UEFI: a trial that boots and then panics is not booted again, the machine is on A — which is
#     what `systemd-bless-boot` defeated, and what would fail here if the image stopped masking it;
#   - the loop device an install attaches takes none of the machine's own partition labels.
#
# **No platform is involved**: the machine's worker has nowhere to connect, so nothing is ever
# accepted, and `keep` is run by hand where a platform's word would have run it. What the worker does
# with the platform's word is `ForgeWorker.UpdateTest`, against a stand-in.
#
# Needs KVM, so it is a flake check rather than a part of `bin/check`:
#
#     nix build .#checks.x86_64-linux.worker-update-boots -L
#
# Its output is observations.txt, everything the guests printed, and the last scenario's console.
{ pkgs, image, newImage, newBuild }:
pkgs.runCommand "forge-worker-update-boots"
{
  nativeBuildInputs = [
    pkgs.qemu_kvm
    pkgs.qemu-utils
    pkgs.openssh
    pkgs.cdrkit
    pkgs.coreutils
    pkgs.gnugrep
  ];
  requiredSystemFeatures = [ "kvm" ];
}
  ''
    qemu-img convert -f qcow2 -O raw ${newImage}/forge-worker.qcow2 new.raw
    bash ${./worker-update-boots/host.sh} \
      ${image}/forge-worker.qcow2 new.raw ${newBuild} ${pkgs.OVMF.fd} $out
  ''
