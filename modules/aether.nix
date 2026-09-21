{
  imports = [ ./deadman.nix ./index.nix ./apply.nix ];

  # Internal composition only: the standalone timer has no apply policy state.
  _module.args.aetherApplyIntegration = true;
}
