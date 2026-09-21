import importlib.util
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("aether_apply", ROOT / "modules/apply.py")
apply = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = apply
spec.loader.exec_module(apply)


class Policy(unittest.TestCase):
    def risk(self, body):
        return apply.scan_module("{ pkgs, ... }: { " + body + " }")

    def test_packages_and_existing_example(self):
        source = (ROOT / "examples/hosts/vps/modules/agent/2026-09-03-ripgrep-and-fd.nix").read_text()
        self.assertEqual(apply.scan_module(source).level, 1)
        self.assertEqual(self.risk("fonts.packages = [ pkgs.dejavu_fonts ];").level, 1)
        self.assertEqual(self.risk("programs.vim.enable = true;").level, 1)

    def test_existing_local_postgres_example(self):
        source = (ROOT / "examples/hosts/vps/modules/agent/2026-09-03-postgres-localhost-only.nix.example").read_text()
        self.assertEqual(apply.scan_module(source).level, 2)

    def test_r3_prefixes_and_ambiguous_services(self):
        for body in (
            "networking.firewall.allowedTCPPorts = [ 22 443 ];",
            "networking = { firewall = { enable = true; }; };",
            "services.openssh.enable = true;",
            "hardware.graphics.enable = true;",
            "services.postgresql.enable = true;",
        ):
            with self.subTest(body=body):
                self.assertEqual(self.risk(body).level, 3)

    def test_boot_only(self):
        for body in (
            'boot.kernelParams = [ "quiet" ];',
            "boot.kernelPackages = pkgs.linuxPackages;",
            "boot.initrd.systemd.enable = true;",
            "hardware.graphics.enable = true;",
        ):
            with self.subTest(body=body):
                risk = self.risk(body)
                self.assertEqual(risk.level, 3)
                self.assertTrue(risk.boot_only)

    def test_r4_prefixes(self):
        for body in (
            "users.users.demo.isNormalUser = true;",
            "boot.loader.grub.enable = true;",
            'fileSystems."/" = { device = "/dev/vda"; };',
            "swapDevices = [];",
            'sops.defaultSopsFile = ./secrets.yaml;',
            "age.secrets.demo = {};",
            "security.sudo.wheelNeedsPassword = false;",
            "services.aether.enable = false;",
        ):
            with self.subTest(body=body), self.assertRaises(apply.Refusal):
                self.risk(body)

    def test_unknown_and_dynamic_are_not_low_risk(self):
        for source in (
            '{ imports = [ ./extra.nix ]; }',
            '{ pkgs, ... }: let x = 1; in {}',
            '{ lib, ... }: lib.mkMerge [ {} ]',
            '{ "${name}".enable = true; }',
            '{ networking = lib.mkIf true { firewall.enable = true; }; }',
            '{ environment.etc."secret".text = "bad"; }',
            '{ systemd.services.demo.script = "echo root"; }',
            '{ services.demo.preStart = "echo root"; }',
            '{ networking.firewall.extraCommands = "echo root"; }',
            '{ services.demo.settings.path = "${builtins.readFile /etc/shadow}"; }',
            '{ environment.systemPackages = pkgs.lib.attrValues pkgs; }',
        ):
            with self.subTest(source=source), self.assertRaises(apply.Refusal):
                apply.scan_module(source)

    def test_comments_and_literal_strings_are_not_assignments(self):
        risk = self.risk('''
          # networking.firewall.enable = false;
          /* users.users.evil = {}; */
          fonts.fontconfig.defaultFonts.monospace = [ "security.notAnOption" ];
          fonts.fontconfig.defaultFonts.serif = [ "with" "[" "}" ];
        ''')
        self.assertEqual(risk.level, 1)

    def test_model_declaration_and_closure_threshold(self):
        source = [("new.nix", "{ networking.firewall.enable = true; }")]
        self.assertEqual(apply.effective_risk(source, 1).level, 3)
        self.assertEqual(apply.effective_risk(source, 4).level, 4)
        self.assertEqual(apply.effective_risk([], 2, "change\n" * 39).level, 2)
        self.assertEqual(apply.effective_risk([], 1, "change\n" * 40).level, 3)
        self.assertEqual(apply.effective_risk([], 1, "\n" * 50).level, 1)

    def test_removed_definitions_keep_risk(self):
        sources = [
            ("HEAD:old.nix", "{ services.openssh.enable = true; }"),
            ("new.nix", "{ programs.vim.enable = true; }"),
        ]
        self.assertEqual(apply.effective_risk(sources).level, 3)

    def test_loader_matches_installed_example_exactly(self):
        self.assertEqual(apply.LOADER, (ROOT / "examples/hosts/vps/modules/agent/default.nix").read_text())
        self.assertEqual(apply.LOADER, (ROOT / "tests/fixtures/apply/hosts/fixture/modules/agent/default.nix").read_text())

    def test_token_binds_candidate_context(self):
        candidate = dict(id="nonce", module_hash="hash", tree="tree", system="system",
                         head="head", host="host", flake="flake", boot="boot", proposer=1000)
        token = apply.token_context(candidate)
        for key in candidate:
            changed = {**candidate, key: "different"}
            self.assertNotEqual(token, apply.token_context(changed), key)

    def test_privileged_subprocess_environment_is_not_inherited(self):
        with patch.dict(os.environ, {
            "GIT_CONFIG_COUNT": "1", "GIT_SSH_COMMAND": "untrusted",
            "NIX_REMOTE": "untrusted", "PYTHONPATH": "untrusted", "BASH_ENV": "untrusted",
        }):
            env = apply.environment({"path": "/declared/tools"})
        self.assertEqual(env["PATH"], "/declared/tools")
        self.assertEqual(env["HOME"], str(apply.STATE / "home"))
        for key in ("GIT_CONFIG_COUNT", "GIT_SSH_COMMAND", "NIX_REMOTE", "PYTHONPATH", "BASH_ENV"):
            self.assertNotIn(key, env)
        self.assertIn("accept-flake-config = false", env["NIX_CONFIG"])

    def test_sudo_identity_is_original_uid_not_effective_root(self):
        with patch.object(apply.os, "geteuid", return_value=0):
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(apply.principal(), 0)
            with patch.dict(os.environ, {"SUDO_UID": "1001", "SUDO_USER": "agent"}, clear=True):
                with patch.object(apply.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="agent")):
                    self.assertEqual(apply.principal(), 1001)
                with patch.object(apply.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="human")):
                    with self.assertRaises(apply.Error):
                        apply.principal()
            with patch.dict(os.environ, {"SUDO_UID": "1001"}, clear=True):
                with self.assertRaises(apply.Error):
                    apply.principal()
        with patch.object(apply.os, "geteuid", return_value=1001):
            with self.assertRaises(apply.Error):
                apply.principal()

    def test_duplicate_flags_fail_before_any_privileged_setup(self):
        for args in (
            ["build", "--risk=R1", "--risk=R3"],
            ["build", "--host=fixture", "--host=another"],
        ):
            with self.subTest(args=args), self.assertRaisesRegex(apply.Error, "only once"):
                apply.apply({}, args)

    def test_refused_diff_shows_new_removed_and_staged_source_without_git(self):
        view = {
            "changed": ["new.nix", "removed.nix", "staged.nix"],
            "contents": {"new.nix": b"{ users.users.new.isNormalUser = true; }\n"},
            "sources": [
                ("HEAD:removed.nix", "{ security.sudo.enable = true; }\n"),
                (":staged.nix", "{ swapDevices = []; }\n"),
            ],
        }
        rendered = apply.refusal_diff(view)
        self.assertIn("+{ users.users.new.isNormalUser = true; }", rendered)
        self.assertIn("-{ security.sudo.enable = true; }", rendered)
        self.assertIn("+++ index:staged.nix", rendered)
        self.assertIn("+{ swapDevices = []; }", rendered)
        self.assertIn("truncated", apply.refusal_diff(view, max_lines=2))
        view["contents"]["new.nix"] = b"# \x1b[2J\n{ users.users.new.isNormalUser = true; }\n"
        self.assertNotIn("\x1b", apply.refusal_diff(view))
        self.assertIn("\\x1b", apply.refusal_diff(view))

    def test_unsafe_boot_profile_blocks_recovery_before_building(self):
        pending = {"id": "transaction", "baseline": "/nix/store/good"}
        with patch.object(apply, "recovery_quiet", return_value=True), \
                patch.object(apply, "active", return_value=False), \
                patch.object(apply, "canonical_system", side_effect=["/nix/store/good", "/nix/store/bad"]), \
                patch.object(apply, "console_recovery"), \
                patch.object(apply, "frozen_candidate") as build:
            with self.assertRaisesRegex(apply.Error, "boot-default profile still differs"):
                apply.recovery_build({}, None, None, None, None, 1000, pending)
            build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
