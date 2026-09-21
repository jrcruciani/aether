#!/usr/bin/env bash
set -euo pipefail

# Networked Linux evidence, deliberately outside the offline NixOS VM check.
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/aether-index.XXXXXX")
export INDEX_FIXTURE="$work/example host"
export INDEX_FLAKE="$INDEX_FIXTURE"
export INDEX_HOST=vps
fixture=$INDEX_FIXTURE
json=/var/lib/nixos-options/share/doc/nixos/options.json
attr=nixosConfigurations.vps.config.system.build.manual.optionsJSON
pins=(
  ac62194c3917d5f474c1a844b6fd6da2db95077d
  b6018f87da91d19d0ab4cf979885689b469cdd41
)
releases=(25.05 25.11)
counts=()

# Refuse to overwrite a real machine's index. Run this on a disposable runner.
if [[ -e /var/lib/nixos-options || -L /var/lib/nixos-options ]]; then
  echo "Refusing to replace an existing /var/lib/nixos-options; use a disposable Linux runner." >&2
  exit 1
fi
mkdir "$fixture"
cp -R "$repo/examples/." "$fixture/"
sed -i 's/networking.hostName = "vps"/networking.hostName = "different-os-name"/' \
  "$fixture/hosts/vps/configuration.nix"

build_helper() {
  nix build --no-link --print-out-paths --impure --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "INDEX_FIXTURE");
      host = flake.nixosConfigurations.vps.extendModules {
        modules = [
          ({ lib, ... }: {
            services.aether.flake = lib.mkForce (builtins.getEnv "INDEX_FLAKE");
            services.aether.host = lib.mkForce (builtins.getEnv "INDEX_HOST");
          })
        ];
      };
    in builtins.head (builtins.filter
      (package: host.pkgs.lib.getName package == "aether-index")
      host.config.environment.systemPackages)
  '
}

run_helper() {
  sudo env -i HOME=/root PATH=/missing "$helper/bin/aether-index" "$@"
}

expect_failure() {
  local message=$1
  shift
  local before after
  before=$(readlink /var/lib/nixos-options)
  if run_helper "$@" > "$work/failure.log" 2>&1; then
    echo "Expected aether-index to fail: $message" >&2
    exit 1
  fi
  cat "$work/failure.log"
  grep -F -- "$message" "$work/failure.log"
  after=$(readlink /var/lib/nixos-options)
  test "$before" = "$after"
}

set_documentation() {
  cp "$repo/examples/flake.nix" "$fixture/flake.nix"
  sed -i "/modules = \\[/a\\        { $1 }" "$fixture/flake.nix"
}

printf 'Release\tHost nixpkgs revision\tOption count\tOptions output\n' > "$work/evidence.tsv"
for i in 0 1; do
  pin=${pins[$i]}
  release=${releases[$i]}
  # The second invocation changes the same fixture lock, not the module files.
  cp "$repo/examples/flake.nix" "$fixture/flake.nix"
  nix flake lock "$fixture" \
    --override-input nixpkgs "github:NixOS/nixpkgs/$pin" \
    --override-input aether "path:$repo"
  jq -e --arg pin "$pin" '.nodes.nixpkgs.locked.rev == $pin' "$fixture/flake.lock"
  cp "$fixture/flake.lock" "$work/flake-$release.lock"
  lock_before=$(sha256sum "$fixture/flake.lock")
  test "$(nix eval --raw --no-update-lock-file \
    "$fixture#nixosConfigurations.vps.config.networking.hostName")" = different-os-name

  # This is the documented attribute on the example host, not nixpkgs-test.
  nix build --no-update-lock-file "$fixture#$attr" -o "$work/direct-$release"
  test -f "$work/direct-$release/share/doc/nixos/options.json"
  helper=$(build_helper)
  run_helper
  test "$(readlink -f /var/lib/nixos-options)" = "$(readlink -f "$work/direct-$release")"
  jq -e 'has("services.openssh.enable") and has("environment.systemPackages")
    and (.["environment.systemPackages"].type | type == "string")' "$json"
  count=$(jq 'length' "$json")
  test "$count" -gt 0
  counts+=("$count")
  printf '%s\t%s\t%s\t%s\n' "$release" "$pin" "$count" \
    "$(readlink -f /var/lib/nixos-options)" | tee -a "$work/evidence.tsv"
  nix eval --raw --no-update-lock-file \
    "$fixture#nixosConfigurations.vps.options.environment.systemPackages.type.description"
  printf '\n'
  test "$(sha256sum "$fixture/flake.lock")" = "$lock_before"

  # Disabling installation of HTML alone must leave the JSON build usable.
  set_documentation 'documentation.doc.enable = false;'
  run_helper
  test -f "$json"
  echo "$release: documentation.doc.enable=false still builds optionsJSON"

  for setting in documentation.nixos.enable documentation.enable; do
    set_documentation "$setting = false;"
    test "$(nix eval --json --impure --expr \
      '(builtins.getFlake (builtins.getEnv "INDEX_FIXTURE")).nixosConfigurations.vps.config.system.build ? manual')" = false
    expect_failure "options build failed; the previous index was not replaced"
    echo "$release: $setting=false removes system.build.manual; old index preserved"
  done
  cp "$repo/examples/flake.nix" "$fixture/flake.nix"
  test "$(sha256sum "$fixture/flake.lock")" = "$lock_before"
done

test "${counts[0]}" != "${counts[1]}"
test "$(jq -r '.nodes.nixpkgs.locked.rev' "$work/flake-25.05.lock")" != \
  "$(jq -r '.nodes.nixpkgs.locked.rev' "$work/flake-25.11.lock")"

expect_failure "takes no arguments" unexpected-argument
mv "$fixture/flake.lock" "$work/saved.lock"
expect_failure "expected flake.nix and flake.lock"
mv "$work/saved.lock" "$fixture/flake.lock"

for invalid_host in '' 'vps.other' 'vps"; echo unsafe'; do
  export INDEX_HOST="$invalid_host"
  helper=$(build_helper)
  expect_failure "set services.aether.host to the nixosConfigurations key"
done
export INDEX_HOST=missing-key_1
helper=$(build_helper)
expect_failure "options build failed; the previous index was not replaced"
export INDEX_HOST=vps
for invalid_flake in relative/path "$fixture#fragment" "$fixture?query" "$fixture"$'\n'; do
  export INDEX_FLAKE="$invalid_flake"
  helper=$(build_helper)
  expect_failure "must be an absolute local directory"
done
export INDEX_FLAKE="$fixture"
helper=$(build_helper)
run_helper
test "$(jq 'length' "$json")" = "${counts[1]}"

cat "$work/evidence.tsv"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '### Host-pinned options index'
    echo
    echo '```text'
    cat "$work/evidence.tsv"
    echo '```'
    echo
    echo 'Both pins: JSON layout and helper build passed with an empty caller PATH.'
    echo 'Both pins: disabling documentation.nixos.enable or documentation.enable removes system.build.manual.'
    echo 'Both pins: documentation.doc.enable=false still builds JSON. Failed builds preserve the old link.'
    echo 'Missing lock, invalid inputs, unknown host and extra arguments fail without replacing the index.'
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "Evidence and fixture locks: $work"
