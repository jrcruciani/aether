{
  name = "aether-deadman";

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

    with subtest("timer-only installation does not guess an index host"):
        error = machine.fail(
            "env -i PATH=/missing /run/current-system/sw/bin/aether-index 2>&1"
        )
        assert "set services.aether.host to the nixosConfigurations key" in error, error
        machine.fail("test -e /var/lib/nixos-options")

    def wait_for_collection():
        machine.wait_until_succeeds(
            "units=$(systemctl list-units --all --plain --no-legend "
            "'deadman-rollback.*') && test -z \"$units\"",
            timeout=30,
        )

    def journal_cursor():
        output = machine.succeed(
            "journalctl --sync && journalctl -n 0 --show-cursor --no-pager"
        )
        assert "-- cursor: " in output, output
        return output.split("-- cursor: ", 1)[1].strip()

    def rollback_journal(cursor):
        return machine.succeed(
            "journalctl --sync && journalctl -u deadman-rollback.service "
            f"--after-cursor='{cursor}' --no-pager --quiet --output=cat"
        )

    # Put a different system at N-1: --rollback would otherwise pass by accident.
    machine.succeed(f"nix-env --profile {profile} --set {broken}")
    machine.succeed(f"nix-env --profile {profile} --set {base}")

    for scenario in ("pinned recovery", "pin beats boot default", "missing pin", "invalid pin"):
        with subtest(scenario):
            cursor = journal_cursor()
            machine.succeed("aether-arm 20s")
            machine.succeed(f"test \"$(cat {pin})\" = {base}")
            boot_default = base
            if scenario == "pin beats boot default":
                # Emulate another switch moving the profile after the timer was armed.
                machine.succeed(f"nix-env --profile {profile} --set {broken}")
                boot_default = broken
            elif scenario == "missing pin":
                machine.succeed(f"rm {pin}")
            elif scenario == "invalid pin":
                # Activatable, but not a canonical store path: it must be rejected.
                machine.succeed(f"printf '%s\\n' {base}/. > {pin}")
            machine.succeed(f"{broken}/bin/switch-to-configuration test")
            machine.succeed(f"test \"$(readlink -f /run/current-system)\" = {broken}")
            machine.succeed(f"test \"$(readlink -f {profile})\" = {boot_default}")
            machine.fail("systemctl is-active --quiet sshd.service")

            machine.wait_until_succeeds(
                f"test \"$(readlink -f /run/current-system)\" = {base} && "
                f"test \"$(readlink -f {profile})\" = {base} && "
                "systemctl is-active --quiet sshd.service",
                timeout=180,
            )
            machine.wait_for_open_port(22)
            wait_for_collection()
            journal = rollback_journal(cursor)
            assert f"aether: rolling back to {base}" in journal, journal
            if scenario in ("missing pin", "invalid pin"):
                assert "WARNING: missing or invalid rollback target" in journal, journal
                assert f"falling back to boot-default profile {profile}" in journal, journal
            else:
                assert "WARNING:" not in journal, journal
            assert "aether: ERROR:" not in journal, journal
            print(f"Recovered running system and profile to {base}; sshd is listening")

    with subtest("disarm prevents rollback past the deadline"):
        cursor = journal_cursor()
        machine.succeed("aether-arm 5s")
        machine.succeed(f"test \"$(cat {pin})\" = {base}")
        machine.succeed("aether-disarm")
        machine.fail(f"test -e {pin}")
        wait_for_collection()
        # Outwait the deadline and systemd's default one-minute timer accuracy.
        machine.succeed("sleep 70")
        machine.succeed(f"test \"$(readlink -f /run/current-system)\" = {base}")
        machine.succeed(f"test \"$(readlink -f {profile})\" = {base}")
        machine.succeed("systemctl is-active --quiet sshd.service")
        wait_for_collection()
        journal = rollback_journal(cursor)
        assert not journal.strip(), journal
        status = machine.succeed("aether-status")
        assert "not armed" in status.splitlines(), status
        assert "rollback target: not pinned" in status.splitlines(), status

    with subtest("a second arm is rejected with a useful message"):
        machine.succeed("aether-arm 5min")
        rejected = machine.fail("aether-arm 1s 2>&1")
        assert f"aether: {timer} is already armed." in rejected, rejected
        assert "Disarm it or let it fire before arming another one." in rejected, rejected
        machine.succeed(f"test \"$(cat {pin})\" = {base}")
        machine.succeed(f"systemctl is-active --quiet {timer}")
        machine.succeed("aether-disarm")
        machine.fail(f"test -e {pin}")
        wait_for_collection()

    with subtest("competing arm preserves the pin; disarm removes it"):
        machine.succeed(
            "(if aether-arm 5min > /tmp/arm-a.log 2>&1; then echo 0; "
            "else echo $?; fi) > /tmp/arm-a.status & "
            "(if aether-arm 5min > /tmp/arm-b.log 2>&1; then echo 0; "
            "else echo $?; fi) > /tmp/arm-b.status & wait"
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
        wait_for_collection()
  '';
}
