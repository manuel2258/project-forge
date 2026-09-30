# Boots the worker image and checks, on the real image and its real systemd, what
# docs/design/worker-tier.md § The job slice and § A machine whose systemd stops answering rely
# on: a job at its memory ceiling loses a process and not its machine, the unit's stop step
# writes the unit's last reading as root, the worker reads its cgroup correctly, a ceiling too
# small to exec wedges PID 1 in the way the worker recognises, the worker's own health process
# notices, `systemctl --force --force reboot` still reboots a wedged machine, and the machine
# comes back as the same worker. docs/measurements.md § The worker at its ceiling, on the image
# has what the first run saw.
#
# Units are started by the release inside the image (nix/worker-health/slice.exs), so the flags,
# the stop step and the reading of what came back are the worker's own and cannot drift from it.
#
# Needs KVM, so it is a flake check rather than a part of `bin/check`:
#
#     nix build .#checks.x86_64-linux.worker-health -L
#
# Its output is observations.txt, everything the guest printed, and the console.
{ pkgs, image }:
pkgs.runCommand "forge-worker-health"
{
  nativeBuildInputs = [
    pkgs.qemu_kvm
    pkgs.openssh
    pkgs.cdrkit
    pkgs.coreutils
    pkgs.gnugrep
  ];
  requiredSystemFeatures = [ "kvm" ];
}
  ''
    bash ${./worker-health/host.sh} ${image}/forge-worker.qcow2 ${./worker-health} $out
  ''
