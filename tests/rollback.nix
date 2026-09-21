{
  name = "aether-deadman";

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ ../modules/deadman.nix ];
    services.aether.enable = true;
    services.openssh.enable = true;
    system.switch.enable = true;
    # The test driver boots the kernel directly, without a bootloader disk.
    boot.loader.grub.enable = false;

    users.users.operator.isNormalUser = true;
    system.activationScripts.aether-test-hold.text = ''
      if [ -e /run/aether-test-enabled ]; then
        ${pkgs.coreutils}/bin/touch /run/aether-test-entered
        while [ -e /run/aether-test-hold ]; do
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        ${pkgs.coreutils}/bin/touch /run/aether-test-completed
      fi
    '';

    specialisation.sshd-off.configuration = {
      services.openssh.enable = lib.mkForce false;
    };

    virtualisation = {
      cores = 2;
      memorySize = 1024;
    };
  };

  testScript = ''
    import json
    import shlex

    machine.start()
    machine.wait_for_unit("sshd.service")
    base = machine.succeed("readlink -f /run/current-system").strip()
    broken = machine.succeed(f"readlink -f {base}/specialisation/sshd-off").strip()
    profile = "/nix/var/nix/profiles/system"
    pin = "/run/aether/rollback-target"
    timer = "deadman-rollback.timer"
    service = "deadman-rollback.service"
    arm = "env -i PATH=/missing /run/current-system/sw/bin/aether-arm"
    disarm = "env -i PATH=/missing /run/current-system/sw/bin/aether-disarm"

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

    def timer_snapshot():
        return machine.succeed(
            f"systemctl show {timer} --property=ActiveState --property=InvocationID "
            "--property=NextElapseUSecMonotonic --property=TimersMonotonic"
        )

    def pin_snapshot():
        return machine.succeed(f"sha256sum {pin}; stat -c '%u:%g:%a:%i:%s:%Y' {pin}")

    with subtest("non-root arm rejects before any state or unit writes"):
        machine.fail("test -e /run/aether")
        error = machine.fail(
            "su -s /bin/sh operator -c " + shlex.quote(arm + " 5min") + " 2>&1"
        )
        assert "aether-arm must run as root; use sudo aether-arm" in error, error
        assert "Permission denied" not in error, error
        machine.fail("test -e /run/aether")
        wait_for_collection()

    with subtest("invalid spans reject before writes, including option-like input"):
        for span in ("not-a-timespan", "-1s", "--help", ""):
            error = machine.fail(arm + " " + shlex.quote(span) + " 2>&1")
            assert "invalid rollback timeout" in error, error
            machine.fail("test -e /run/aether")
            wait_for_collection()

    with subtest("invalid spans preserve an existing pin and live timer"):
        machine.succeed(arm + " '5min 30s'")
        before_pin, before_timer = pin_snapshot(), timer_snapshot()
        for span in ("not-a-timespan", "-1s", "--help", ""):
            error = machine.fail(arm + " " + shlex.quote(span) + " 2>&1")
            assert "invalid rollback timeout" in error, error
            assert before_pin == pin_snapshot()
            assert before_timer == timer_snapshot()
        machine.succeed(disarm)
        machine.fail(f"test -e {pin}")
        wait_for_collection()

    with subtest("systemd spans and default timeout arm and disarm with closed PATH"):
        for argument in ("", " '2min 500ms'", " 90", " 1.5min"):
            machine.succeed(arm + argument)
            machine.succeed(f"test \"$(cat {pin})\" = {base}")
            machine.succeed(f"systemctl is-active --quiet {timer}")
            machine.succeed(disarm)
            machine.fail(f"test -e {pin}")
            wait_for_collection()

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

    for state in ("active", "activating", "deactivating", "queued"):
        with subtest(f"disarm refuses {state} rollback without interrupting activation or state"):
            cursor = journal_cursor()
            machine.succeed(arm + " 5min")
            machine.succeed("touch /run/aether-test-enabled")
            dropin = "/run/systemd/system/" + service + ".d/aether-test.conf"
            if state in ("active", "activating"):
                machine.succeed("touch /run/aether-test-hold")
            if state == "activating":
                configuration = "[Service]\nType=oneshot\n"
            elif state == "deactivating":
                machine.succeed("touch /run/aether-test-stop-hold")
                configuration = (
                    "[Service]\nExecStopPost=/bin/sh -c '"
                    "/run/current-system/sw/bin/touch /run/aether-test-stopping; "
                    "while test -e /run/aether-test-stop-hold; do /run/current-system/sw/bin/sleep 0.1; done; "
                    "/run/current-system/sw/bin/touch /run/aether-test-stopped'\n"
                )
            elif state == "queued":
                machine.succeed(
                    "touch /run/aether-test-block && "
                    "systemd-run --no-block --collect --unit=aether-test-blocker "
                    "--property=Type=oneshot /bin/sh -c "
                    + shlex.quote("while test -e /run/aether-test-block; do /run/current-system/sw/bin/sleep 0.1; done")
                )
                machine.wait_until_succeeds(
                    "test \"$(systemctl show aether-test-blocker.service -p ActiveState --value)\" = activating"
                )
                configuration = "[Unit]\nAfter=aether-test-blocker.service\n"
            else:
                configuration = "[Service]\n"
            machine.succeed(
                f"mkdir -p /run/systemd/system/{service}.d && printf %s "
                + shlex.quote(configuration) + f" > {dropin} && systemctl daemon-reload"
            )
            machine.succeed(f"systemctl start --no-block {service}")
            expected_state = "inactive" if state == "queued" else state
            machine.wait_until_succeeds(
                f"test \"$(systemctl show {service} -p ActiveState --value)\" = {expected_state}"
            )
            if state in ("active", "activating"):
                machine.wait_until_succeeds("test -e /run/aether-test-entered")
                machine.fail("test -e /run/aether-test-completed")
            elif state == "deactivating":
                machine.wait_until_succeeds("test -e /run/aether-test-stopping")
            else:
                machine.wait_until_succeeds(
                    f"systemctl list-jobs --no-legend | grep -E '{service} +start +waiting'"
                )
                machine.fail("test -e /run/aether-test-entered")

            # Seed after recovery-begin: refusal must not revoke even a leftover token.
            candidate = "/run/aether/candidate.json"
            token = "/run/aether/confirmed-" + "a" * 64
            machine.succeed(
                "printf %s " + shlex.quote(json.dumps({"module_hash": "a" * 64}))
                + f" > {candidate} && printf sentinel > {token} && chmod 600 {candidate} {token}"
            )
            snapshot_command = (
                f"sha256sum {candidate} {token}; stat -c '%u:%g:%a:%i:%s:%Y' {candidate} {token}; "
                f"systemctl show {service} -p ActiveState -p MainPID -p ControlPID -p InvocationID -p Job"
            )
            before_pin, before_timer = pin_snapshot(), timer_snapshot()
            before_state = machine.succeed(snapshot_command)
            error = machine.fail(disarm + " 2>&1")
            assert "rollback in progress, do not interrupt" in error, error
            assert before_pin == pin_snapshot()
            assert before_timer == timer_snapshot()
            assert before_state == machine.succeed(snapshot_command)
            machine.succeed(f"systemctl is-active --quiet {timer}")
            machine.succeed(
                f"rm {candidate} {token}; "
                "rm -f /run/aether-test-hold /run/aether-test-stop-hold /run/aether-test-block"
            )
            machine.wait_until_succeeds(
                "test -e /run/aether-test-completed && "
                f"test \"$(systemctl show {service} -p ActiveState --value)\" = inactive",
                timeout=180,
            )
            if state == "deactivating":
                machine.succeed("test -e /run/aether-test-stopped")
            machine.succeed(
                f"test \"$(systemctl show {service} -p ExecMainStatus --value)\" = 0 && "
                f"test \"$(readlink -f /run/current-system)\" = {base} && "
                f"test \"$(readlink -f {profile})\" = {base} && "
                "systemctl is-active --quiet sshd.service"
            )
            journal = rollback_journal(cursor)
            assert f"aether: rolling back to {base}" in journal, journal
            assert "aether: ERROR:" not in journal, journal
            machine.succeed(disarm)
            machine.succeed(
                f"rm {dropin} && systemctl daemon-reload && "
                "rm -f /run/aether-test-enabled /run/aether-test-entered /run/aether-test-completed "
                "/run/aether-test-stopping /run/aether-test-stopped"
            )
            wait_for_collection()

    with subtest("a recovery marker refuses disarm even with an inactive service"):
        machine.succeed(arm + " 5min")
        machine.succeed("printf true > /run/aether/recovering.json")
        before_pin, before_timer = pin_snapshot(), timer_snapshot()
        error = machine.fail(disarm + " 2>&1")
        assert "rollback in progress, do not interrupt" in error, error
        assert before_pin == pin_snapshot()
        assert before_timer == timer_snapshot()
        machine.succeed("test \"$(cat /run/aether/recovering.json)\" = true")
        machine.succeed("rm /run/aether/recovering.json")
        machine.succeed(disarm)
        wait_for_collection()

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
