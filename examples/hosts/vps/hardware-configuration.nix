# Placeholder. Generate the real one on your machine with:
#   nixos-generate-config --root /mnt
# Never hand-write this and never let the agent invent it.

{ ... }:

{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  swapDevices = [ ];
}
