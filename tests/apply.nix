{ hostPkgs, lib, ... }:
let
  pkgs = hostPkgs;
  nixosLib = import (pkgs.path + "/nixos/lib") { };
  aetherSource = lib.cleanSource ../.;
  packages = "{ pkgs, ... }: { environment.systemPackages = with pkgs; [ ripgrep fd ]; }";
  firewall = "{ networking.firewall.allowedTCPPorts = [ 8443 ]; }";
  evaluate = extra: (nixosLib.evalTest {
    hostPkgs = pkgs;
    name = "aether-apply-fixture";
    nodes.machine.imports = [ ./apply-host.nix extra ];
    testScript = "";
  }).config.nodes.machine.system.build.toplevel;
  base = evaluate { };
  tools = evaluate ({ pkgs, ... }: {
    environment.systemPackages = [ pkgs.ripgrep pkgs.fd ];
  });
  network = evaluate ({ pkgs, ... }: {
    environment.systemPackages = [ pkgs.ripgrep pkgs.fd ];
    networking.firewall.allowedTCPPorts = [ 8443 ];
  });
  networkOnly = evaluate { networking.firewall.allowedTCPPorts = [ 8443 ]; };
  fixture = pkgs.writeText "fixture-flake.nix" ''
    {
      inputs.nixpkgs.url = "path:${pkgs.path}";
      inputs.aether.url = "path:${aetherSource}";
      inputs.aether.inputs.nixpkgs-test.follows = "nixpkgs";
      outputs = { nixpkgs, aether, ... }:
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          evaluation = (import (nixpkgs + "/nixos/lib") {}).evalTest {
            hostPkgs = pkgs;
            name = "aether-apply-fixture";
            nodes.machine.imports = [
              (aether + "/tests/apply-host.nix")
              ./hosts/fixture/modules/agent
            ];
            testScript = "";
          };
        in {
          nixosConfigurations.fixture = {
            config = evaluation.config.nodes.machine;
            inherit pkgs;
          };
        };
    }
  '';
in
{
  name = "aether-apply";
  nodes.machine = {
    imports = [ ./apply-host.nix ];
    virtualisation.additionalPaths = [ pkgs.path aetherSource base tools network networkOnly ];
  };
  testScript = ''
    import json
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")
    repo = "/etc/nixos"
    proposals = repo + "/hosts/fixture/modules/agent"
    package_file = proposals + "/tools.nix"
    firewall_file = proposals + "/firewall.nix"
    apply = "/run/current-system/sw/bin/aether-apply"
    confirm = "/run/current-system/sw/bin/aether-confirm"
    profile = "/nix/var/nix/profiles/system"
    timer = "deadman-rollback.timer"

    def agent(command, fail=False):
        shell = "su -s /bin/sh agent -c " + shlex.quote(command) + " 2>&1"
        return (machine.fail if fail else machine.succeed)(shell)

    def propose(path, text):
        agent("printf %s " + shlex.quote(text) + " > " + shlex.quote(path))

    def run(verb, risk="R1", fail=False):
        return agent(f"sudo -n {apply} {verb} --risk {risk}", fail)

    def head():
        return machine.succeed(f"git -C {repo} rev-parse HEAD").strip()

    def pending():
        return json.loads(machine.succeed("cat /var/lib/aether/pending.json"))

    def running():
        return machine.succeed("readlink -f /run/current-system").strip()

    def wait_for_recovery(expected):
        machine.wait_until_succeeds(
            f"test \"$(readlink -f /run/current-system)\" = {expected} && "
            f"test \"$(readlink -f {profile})\" = {expected} && "
            "test ! -e /run/aether/recovering.json && "
            "! systemctl is-active --quiet deadman-rollback.timer",
            timeout=180,
        )
        machine.wait_for_unit("sshd.service")

    def clean_failed():
        agent("rm -- " + firewall_file)
        result = run("build")
        assert "repo matches running system" in result, result
        machine.fail("test -e /var/lib/aether/pending.json")

    machine.succeed(
        f"mkdir -p {proposals} && "
        f"cp ${fixture} {repo}/flake.nix && "
        f"cp ${../examples/hosts/vps/modules/agent/default.nix} {proposals}/default.nix && "
        f"printf 'result\\n' > {repo}/.gitignore && "
        f"chown root:agent {proposals} && chmod 1775 {proposals} && "
        f"git -C {repo} init && git -C {repo} config user.name Fixture && "
        f"git -C {repo} config user.email fixture@localhost && "
        f"git -C {repo} add -A && nix flake lock {repo} && "
        f"git -C {repo} add -A && git -C {repo} commit -m baseline"
    )
    # Bootstrap the actual fixture baseline; subsequent builds must reproduce it.
    machine.succeed(f"nixos-rebuild build --flake {repo}#fixture --no-update-lock-file")
    fixture_base = machine.succeed("readlink -f result").strip()
    machine.succeed(
        f"nix-env --profile {profile} --set {fixture_base} && "
        f"{fixture_base}/bin/switch-to-configuration switch"
    )
    machine.wait_for_unit("sshd.service")
    assert running() == fixture_base
    machine.succeed(
        "ssh-keygen -q -t ed25519 -N \"\" -f /root/human-key && "
        "install -d -m 700 -o human -g users /home/human/.ssh && "
        "install -m 600 -o human -g users /root/human-key.pub /home/human/.ssh/authorized_keys"
    )

    def human_confirm(fail=False):
        command = (
            "ssh -i /root/human-key -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null human@localhost "
            + shlex.quote("sudo -n " + confirm)
        )
        return (machine.fail if fail else machine.succeed)(command + " 2>&1")

    with subtest("actual sudoers and protected importer"):
        for command in (
            "nixos-rebuild switch", f"{fixture_base}/bin/switch-to-configuration switch",
            confirm, "aether-disarm", "sh -c id", "systemctl stop sshd",
            "nix-env --profile /nix/var/nix/profiles/system --set " + fixture_base,
        ):
            agent("sudo -n " + command, fail=True)
        agent("rm " + proposals + "/default.nix", fail=True)
        agent("printf bad > " + proposals + "/default.nix", fail=True)
        agent(f"sudo -n NIX_REMOTE=ssh://invalid {apply} build", fail=True)
        agent(f"env -i PATH=/missing /run/wrappers/bin/sudo -n {apply} build")
        run("build", risk="R3")
        error = run("switch", fail=True)
        assert "R3 switch requires" in error, error
        agent(f"sudo -n {apply} build --host not-the-flake-key", fail=True)

    with subtest("R4 and unsupported forms do not mutate transaction or Git"):
        before = machine.succeed(
            f"git -C {repo} write-tree; git -C {repo} rev-parse HEAD; "
            "readlink -f /etc/nixos/result; sha256sum /run/aether/candidate.json"
        )
        for body in (
            "{ users.users.bad.isNormalUser = true; }",
            "{ imports = [ ./unknown.nix ]; }",
            '{ "$' + '{name}".enable = true; }',
        ):
            propose(proposals + "/refused.nix", body)
            error = run("build", fail=True)
            assert "manual" in error, error
            after = machine.succeed(
                f"git -C {repo} write-tree; git -C {repo} rev-parse HEAD; "
                "readlink -f /etc/nixos/result; sha256sum /run/aether/candidate.json"
            )
            assert before == after, (before, after)
            agent("rm " + proposals + "/refused.nix")
        error = run("switch", risk="R4", fail=True)
        assert "model-declared R4" in error, error

    with subtest("unexpected dirty files and links fail before staging"):
        machine.succeed(f"printf unexpected > {repo}/unexpected")
        error = run("build", fail=True)
        assert "unexpected dirty path" in error, error
        machine.succeed(f"rm {repo}/unexpected")
        agent(f"ln -s /etc/passwd {proposals}/link.nix")
        run("build", fail=True)
        agent(f"rm {proposals}/link.nix")

    with subtest("hardware and kernel are R3 build-only, never a silent live test"):
        for body in (
            "{ hardware.graphics.enable = true; }",
            '{ boot.kernelParams = [ "quiet" ]; }',
        ):
            propose(proposals + "/boot-only.nix", body)
            before = machine.succeed(f"git -C {repo} write-tree; git -C {repo} rev-parse HEAD")
            for verb in ("test", "switch"):
                error = run(verb, fail=True)
                assert "effective risk R3" in error and "build-only" in error, error
            assert before == machine.succeed(f"git -C {repo} write-tree; git -C {repo} rev-parse HEAD")
            agent("rm " + proposals + "/boot-only.nix")

    with subtest("R1 ripgrep and fd build and switch exact staged/new module"):
        before = head()
        propose(package_file, ${builtins.toJSON packages})
        machine.succeed(f"git -C {repo} add hosts/fixture/modules/agent/tools.nix")
        output = run("build")
        assert "effective risk R1" in output, output
        candidate = machine.succeed("readlink -f /etc/nixos/result").strip()
        assert head() == before
        run("switch")
        assert running() == candidate
        assert head() != before
        machine.succeed("rg --version && fd --version")
        machine.succeed(f"test \"$(readlink -f {profile})\" = {candidate}")
        machine.fail("test -e /run/aether/rollback-target")
        machine.fail("test -e /var/lib/aether/pending.json")
        assert not machine.succeed(f"git -C {repo} status --porcelain").strip()
    good = running()

    with subtest("R3 cannot be downgraded, confirmed by agent or switched without human"):
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        error = run("switch", fail=True)
        assert "R3 switch requires" in error, error
        run("test")
        candidate = running()
        assert candidate != good
        assert head() == before
        machine.succeed(f"test \"$(cat /run/aether/rollback-target)\" = {good}")
        agent("sudo -n " + confirm, fail=True)
        error = run("switch", fail=True)
        assert "R3 switch requires" in error, error
        human_confirm()
        machine.fail(f"systemctl is-active --quiet {timer}")
        machine.fail("test -e /run/aether/rollback-target")
        token = "/run/aether/confirmed-" + pending()["module_hash"]
        original = machine.succeed("cat " + token)
        foreign = json.loads(original)
        foreign["id"] = "a-different-transaction"
        machine.succeed("printf %s " + shlex.quote(json.dumps(foreign)) + " > " + token)
        run("switch", fail=True)
        assert head() == before
        machine.succeed(f"test \"$(readlink -f {profile})\" = {good}")
        machine.succeed("printf %s " + shlex.quote(original) + " > " + token)
        run("switch")
        assert running() == candidate
        assert head() != before
        human_confirm(fail=True)
        machine.succeed("test -z \"$(find /run/aether -name 'confirmed-*' -print)\"")

    # Restore the known package-only committed baseline through a human operation.
    machine.succeed(
        f"git -C {repo} revert --no-edit HEAD && "
        f"nix-env --profile {profile} --set {good} && {good}/bin/switch-to-configuration switch"
    )

    with subtest("edited human token is revoked and cannot silently rebuild"):
        propose(firewall_file, ${builtins.toJSON firewall})
        run("test")
        human_confirm()
        propose(firewall_file, ${builtins.toJSON (firewall + "\n# edited after review\n")})
        error = run("switch", fail=True)
        assert "confirmation revoked" in error, error
        machine.succeed("test -z \"$(find /run/aether -name 'confirmed-*' -print)\"")
        machine.succeed(f"nix-env --profile {profile} --set {good} && {good}/bin/switch-to-configuration switch")
        clean_failed()

    with subtest("failed disarm cannot create human approval"):
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        run("test")
        machine.succeed(
            "mkdir -p /run/systemd/system/deadman-rollback.timer.d && "
            "printf '[Unit]\\nRefuseManualStop=yes\\n' "
            "> /run/systemd/system/deadman-rollback.timer.d/refuse.conf && systemctl daemon-reload"
        )
        human_confirm(fail=True)
        machine.succeed("test -z \"$(find /run/aether -name 'confirmed-*' -print)\"")
        run("switch", fail=True)
        assert head() == before
        machine.succeed(
            "rm /run/systemd/system/deadman-rollback.timer.d/refuse.conf && "
            "rmdir /run/systemd/system/deadman-rollback.timer.d && systemctl daemon-reload"
        )
        wait_for_recovery(good)
        clean_failed()

    with subtest("real arm failure cannot activate or commit"):
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        machine.succeed(
            "printf '[Service]\\nType=oneshot\\nExecStart=/bin/true\\n' "
            "> /run/systemd/system/deadman-rollback.service && systemctl daemon-reload"
        )
        run("test", fail=True)
        assert running() == good and head() == before
        machine.succeed("rm /run/systemd/system/deadman-rollback.service && systemctl daemon-reload")
        clean_failed()

    with subtest("rollback cancels blocked real activation without waiting for apply lock"):
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        machine.succeed(
            "touch /run/block-candidate && "
            "systemd-run --unit=fixture-agent-apply /bin/sh -c "
            + shlex.quote(f"su -s /bin/sh agent -c '/run/wrappers/bin/sudo -n {apply} test'")
        )
        machine.wait_until_succeeds(f"systemctl is-active --quiet {timer}", timeout=60)
        machine.wait_until_succeeds(
            "jq -e '.activation_started == true' /var/lib/aether/pending.json", timeout=30
        )
        error = run("test", fail=True)
        assert "busy" in error, error
        machine.wait_until_succeeds(
            "jq -e '.phase == \"recovery-required\"' /var/lib/aether/pending.json", timeout=180
        )
        wait_for_recovery(good)
        assert head() == before
        machine.succeed("rm /run/block-candidate")
        clean_failed()

    with subtest("failed real candidate activation recovers and remains uncommitted"):
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        machine.succeed("touch /run/fail-candidate")
        run("test", fail=True)
        wait_for_recovery(good)
        assert head() == before
        machine.succeed("rm /run/fail-candidate")
        clean_failed()

    with subtest("reboot destroys approval, preserves recovery gate and checks equality"):
        # Direct-boot tests reboot their original init, not a bootloader generation.
        # Make the captured baseline exactly that original fixture for this case.
        machine.succeed(
            f"git -C {repo} rm hosts/fixture/modules/agent/tools.nix && "
            f"git -C {repo} commit -m 'Return fixture to its direct-boot baseline' && "
            f"nix-env --profile {profile} --set {fixture_base} && "
            f"{fixture_base}/bin/switch-to-configuration switch"
        )
        good = fixture_base
        before = head()
        propose(firewall_file, ${builtins.toJSON firewall})
        run("test")
        human_confirm()
        machine.reboot()
        machine.wait_for_unit("sshd.service")
        assert running() == good and head() == before
        machine.succeed("test -z \"$(find /run/aether -name 'confirmed-*' -print 2>/dev/null)\"")
        run("switch", fail=True)
        error = run("build", fail=True)
        assert "DIVERGE" in error, error
        clean_failed()
  '';
}
