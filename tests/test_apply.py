import importlib.util
from pathlib import Path
import sys
import unittest


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

    def test_token_binds_candidate_context(self):
        candidate = dict(id="nonce", module_hash="hash", tree="tree", system="system",
                         head="head", host="host", flake="flake", boot="boot", proposer=1000)
        token = apply.token_context(candidate)
        for key in candidate:
            changed = {**candidate, key: "different"}
            self.assertNotEqual(token, apply.token_context(changed), key)


if __name__ == "__main__":
    unittest.main()
