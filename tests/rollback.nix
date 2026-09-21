{
  name = "aether-rollback";

  nodes.machine = { lib, ... }: {
    imports = [ ../modules/deadman.nix ];
    services.aether.enable = true;
    services.openssh.enable = true;
    system.switch.enable = true;
    # The test driver boots the kernel directly, without a bootloader disk.
    boot.loader.grub.enable = false;

    specialisation.sshd-off.configuration = {
      services.openssh.enable = lib.mkForce false;
    };

    virtualisation = {
      cores = 2;
      memorySize = 1024;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("sshd.service")
    base = machine.succeed("readlink -f /run/current-system").strip()
    broken = machine.succeed(f"readlink -f {base}/specialisation/sshd-off").strip()
    profile = "/nix/var/nix/profiles/system"
    pin = "/run/aether/rollback-target"
    timer = "deadman-rollback.timer"

    # Put a different system at N-1: --rollback would otherwise pass by accident.
    machine.succeed(f"nix-env --profile {profile} --set {broken}")
    machine.succeed(f"nix-env --profile {profile} --set {base}")

    with subtest("competing arm preserves the pin; disarm removes it"):
        machine.succeed(
            "(aether-arm 5min; echo $? > /tmp/arm-a.status) & "
            "(aether-arm 5min; echo $? > /tmp/arm-b.status) & wait"
        )
        results = sorted(
            machine.succeed(f"cat /tmp/arm-{name}.status").strip()
            for name in ("a", "b")
        )
        assert results == ["0", "1"], results
        status = machine.succeed("aether-status")
        assert base in status and "ARMED" in status and "LEFT" in status, status
        machine.succeed(f"test \"$(cat {pin})\" = {base}")
        machine.succeed("aether-disarm")
        machine.fail(f"test -e {pin}")
        machine.wait_until_fails(f"systemctl is-active --quiet {timer}")

    for missing_pin in (False, True):
        with subtest("boot-default fallback" if missing_pin else "pinned recovery"):
            machine.succeed("aether-arm 20s")
            machine.succeed(f"test \"$(cat {pin})\" = {base}")
            if missing_pin:
                machine.succeed(f"rm {pin}")
            machine.succeed(f"{broken}/bin/switch-to-configuration test")
            machine.succeed(f"test \"$(readlink -f /run/current-system)\" = {broken}")
            machine.succeed(f"test \"$(readlink -f {profile})\" = {base}")
            machine.fail("systemctl is-active --quiet sshd.service")

            machine.wait_until_succeeds(
                f"test \"$(readlink -f /run/current-system)\" = {base} && "
                f"test \"$(readlink -f {profile})\" = {base} && "
                "systemctl is-active --quiet sshd.service",
                timeout=180,
            )
            machine.wait_for_open_port(22)
            machine.wait_until_fails(f"systemctl is-active --quiet {timer}")
            machine.wait_until_fails("systemctl is-active --quiet deadman-rollback.service")
            journal = machine.succeed("journalctl -u deadman-rollback.service --no-pager")
            assert f"aether: rolling back to {base}" in journal, journal
            if missing_pin:
                assert "WARNING: missing or invalid rollback target" in journal, journal
                assert f"falling back to boot-default profile {profile}" in journal, journal
            else:
                assert "WARNING:" not in journal, journal
            assert "aether: ERROR:" not in journal, journal
            print(f"Recovered running system and profile to {base}; sshd is listening")
  '';
}
