"""A small, deliberately conservative policy gate; not a Nix sandbox."""

import argparse
import contextlib
import dataclasses
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import uuid


RUN = Path("/run/aether")
STATE = Path("/var/lib/aether")
PROFILE = Path("/nix/var/nix/profiles/system")
R4 = ("users", "boot.loader", "fileSystems", "swapDevices", "sops", "age",
      "security", "services.aether")
R3 = ("networking", "services.openssh", "boot.kernel", "hardware")
PACKAGE_OPTIONS = {"environment.systemPackages", "fonts.packages"}
PROGRAMS = {"bash", "zsh", "fish", "vim", "neovim", "git", "tmux", "htop"}
LOCAL_POSTGRES = {"enable", "enableTCPIP", "package", "authentication"}
SAFE_GIT = [
    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
    "-c", "core.attributesFile=/dev/null", "-c", "commit.gpgSign=false",
    "-c", "tag.gpgSign=false", "-c", "submodule.recurse=false",
    "-c", "protocol.ext.allow=never", "-c", "core.quotePath=false",
]


class Error(Exception):
    pass


class Refusal(Error):
    pass


@dataclasses.dataclass(frozen=True)
class Package:
    name: str


@dataclasses.dataclass
class Risk:
    level: int = 1
    reasons: list = dataclasses.field(default_factory=list)
    boot_only: bool = False

    def raise_to(self, level, reason):
        self.level = max(self.level, level)
        if reason not in self.reasons:
            self.reasons.append(reason)


def matches(path, prefix):
    if prefix in ("boot.kernel", "boot.loader"):
        return path.startswith(prefix)
    return path == prefix or path.startswith(prefix + ".")


def tokens(source):
    result = []
    pos = 0
    while pos < len(source):
        if source[pos].isspace():
            pos += 1
        elif source[pos] == "#":
            end = source.find("\n", pos)
            pos = len(source) if end < 0 else end + 1
        elif source.startswith("/*", pos):
            end = source.find("*/", pos + 2)
            if end < 0 or "/*" in source[pos + 2:end]:
                raise Refusal("unsupported or unterminated block comment")
            pos = end + 2
        elif source.startswith("''", pos):
            end = source.find("''", pos + 2)
            if end < 0 or (end + 2 < len(source) and source[end + 2] in "'$\\"):
                raise Refusal("unsupported indented-string escape")
            value = source[pos + 2:end]
            if "${" in value:
                raise Refusal("string interpolation requires manual review")
            result.append(("string", value))
            pos = end + 2
        elif source[pos] == '"':
            end = pos + 1
            value = ""
            while end < len(source) and source[end] != '"':
                if source[end] == "\\":
                    end += 1
                    if end >= len(source) or source[end] not in '"\\nrt':
                        raise Refusal("unsupported string escape")
                    value += {"n": "\n", "r": "\r", "t": "\t"}.get(
                        source[end], source[end])
                else:
                    value += source[end]
                end += 1
            if end == len(source) or "${" in value:
                raise Refusal("unterminated string or string interpolation")
            result.append(("string", value))
            pos = end + 1
        else:
            match = re.match(r"[A-Za-z_][A-Za-z0-9_'-]*|-?[0-9]+|\.\.\.", source[pos:])
            if match:
                value = match.group()
                result.append(("word", value))
                pos += len(value)
            elif source[pos] in "{}[]:;=.,":
                result.append((source[pos], source[pos]))
                pos += 1
            else:
                raise Refusal(f"unsupported Nix syntax near {source[pos:pos + 24]!r}")
    return result


class ModuleReader:
    def __init__(self, source):
        self.items = tokens(source)
        self.pos = 0
        self.assignments = {}

    def peek(self, value=None):
        item = self.items[self.pos] if self.pos < len(self.items) else ("end", "")
        return item if value is None else item[1] == value

    def take(self, value=None):
        item = self.peek()
        if item[0] == "end" or (value is not None and item[1] != value):
            raise Refusal(f"expected {value or 'a value'}, found {item[1] or 'end of module'}")
        self.pos += 1
        return item

    def read(self):
        # Only a plain argument set is accepted, without defaults or expressions.
        if self.peek("{"):
            end = next((i for i, item in enumerate(self.items)
                        if item[1] == "}"), -1)
            if end >= 0 and end + 1 < len(self.items) and self.items[end + 1][1] == ":":
                args = self.items[1:end]
                if any(kind != "," and not (kind == "word" and value in
                       {"pkgs", "config", "lib", "options", "modulesPath", "..."})
                       for kind, value in args):
                    raise Refusal("unsupported module arguments")
                self.pos = end + 2
        self.attributes(())
        if self.pos != len(self.items):
            raise Refusal("trailing or computed module expression")
        return self.assignments

    def attributes(self, prefix):
        self.take("{")
        while not self.peek("}"):
            path = list(prefix)
            while True:
                kind, value = self.take()
                if kind not in ("word", "string") or value in (
                        "inherit", "imports", "let", "rec", "with", "..."):
                    raise Refusal("imports, inheritance and computed attributes are unsupported")
                path.append(value)
                if not self.peek("."):
                    break
                self.take(".")
            name = ".".join(path)
            if any(matches(name, item) for item in R4):
                raise Refusal(f"R4 option {name}")
            if name == "imports" or name.startswith(("system.activationScripts", "systemd.")):
                raise Refusal(f"unsupported executable/module option {name}")
            self.take("=")
            if self.peek("{"):
                before = len(self.assignments)
                self.attributes(tuple(path))
                if len(self.assignments) == before:
                    self.assignments[name] = {}
            else:
                if name in self.assignments:
                    raise Refusal(f"duplicate definition of {name}")
                self.assignments[name] = self.value()
            self.take(";")
        self.take("}")

    def value(self, packages=False):
        if self.peek("with"):
            self.take("with")
            self.take("pkgs")
            self.take(";")
            if not self.peek("["):
                raise Refusal("with pkgs is supported only for a package list")
            return self.value(packages=True)
        if self.peek("["):
            self.take("[")
            values = []
            while not self.peek("]"):
                values.append(self.value(packages))
            self.take("]")
            return values
        kind, value = self.take()
        if kind == "string":
            return value
        if value in ("true", "false"):
            return value == "true"
        if re.fullmatch(r"-?[0-9]+", value):
            return int(value)
        if kind != "word" or value in ("let", "if", "null", "rec"):
            raise Refusal("only literal values and package references are supported")
        parts = [value]
        while self.peek("."):
            self.take(".")
            item = self.take()
            if item[0] != "word":
                raise Refusal("computed package reference")
            parts.append(item[1])
        if len(parts) > 1 and parts[0] == "pkgs":
            return Package(".".join(parts))
        if packages and value not in ("config", "lib", "builtins"):
            return Package("pkgs." + ".".join(parts))
        raise Refusal(f"unsupported expression {'.'.join(parts)}")


def scan_module(source):
    assignments = ModuleReader(source).read()
    risk = Risk()
    postgres_local = assignments.get("services.postgresql.enableTCPIP") is False
    for name, value in assignments.items():
        if any(matches(name, prefix) for prefix in R3):
            risk.raise_to(3, name)
            risk.boot_only |= name.startswith("boot.kernel")
        elif name.startswith("boot.initrd"):
            risk.raise_to(3, name)
            risk.boot_only = True
        elif name in PACKAGE_OPTIONS:
            if not isinstance(value, list) or not all(isinstance(x, Package) for x in value):
                raise Refusal(f"{name} requires a static package list")
        elif name == "fonts.fontconfig.enable" or name.startswith("fonts.fontconfig.defaultFonts."):
            pass
        elif re.fullmatch(r"programs\.([A-Za-z]+)\.enable", name):
            if name.split(".")[1] not in PROGRAMS or not isinstance(value, bool):
                raise Refusal(f"unsupported user-program setting {name}")
        elif name.startswith("services.postgresql.") and postgres_local and (
                name.removeprefix("services.postgresql.") in LOCAL_POSTGRES):
            risk.raise_to(2, "explicit local-only PostgreSQL")
        elif name in ("services.postgresqlBackup.enable", "services.postgresqlBackup.startAt"):
            risk.raise_to(2, "PostgreSQL backup schedule")
        elif name.startswith("services."):
            if any(part in {"script", "preStart", "postStart", "preStop", "postStop"}
                   for part in name.split(".")):
                raise Refusal(f"executable service setting {name} requires manual review")
            risk.raise_to(3, f"service exposure is not established: {name}")
        else:
            raise Refusal(f"unsupported option family {name}")
    if not risk.reasons:
        risk.reasons.append("static packages/fonts/user programs")
    return risk


def effective_risk(sources, declared=1, diff=None):
    risk = Risk()
    for path, source in sources:
        try:
            found = scan_module(source)
        except Refusal as exc:
            raise Refusal(f"{path}: {exc}") from exc
        risk.boot_only |= found.boot_only
        for reason in found.reasons:
            risk.raise_to(found.level, f"{path}: {reason}")
    if declared > 1:
        risk.raise_to(declared, f"model-declared R{declared} (cannot lower the floor)")
    if diff is not None:
        lines = sum(bool(line.strip()) for line in diff.splitlines())
        if lines >= 40:
            risk.raise_to(3, f"closure diff has {lines} nonempty lines (threshold 40)")
    return risk


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise Error(f"cannot read transaction state {path}: {exc}") from exc


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    with temporary.open("x", encoding="utf-8") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def canonical_system(path):
    target = Path(path).resolve(strict=True)
    if target.parent != Path("/nix/store") or not (target / "bin/switch-to-configuration").is_file():
        raise Error(f"{path} is not an activatable store system")
    return str(target)


def root_required():
    if os.geteuid() != 0:
        raise Error("run this helper through the documented sudo policy")


def principal():
    root_required()
    uid = os.environ.get("SUDO_UID")
    user = os.environ.get("SUDO_USER")
    if uid is None and user is None:
        return 0
    if uid is None or user is None or not uid.isdecimal():
        raise Error("incomplete sudo identity")
    number = int(uid)
    try:
        account = pwd.getpwuid(number)
    except KeyError as exc:
        raise Error("unknown sudo identity") from exc
    if account.pw_name != user:
        raise Error("inconsistent sudo identity")
    return number


def environment(config):
    return {
        "PATH": config["path"], "HOME": "/var/empty", "LC_ALL": "C.UTF-8",
        "TERM": "dumb", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_OPTIONAL_LOCKS": "0", "NIX_USER_CONF_FILES": "/dev/null",
        "NIX_CONFIG": "experimental-features = nix-command flakes\naccept-flake-config = false\n",
    }


def command(config, args, cwd=None, capture=False, data=None, timeout=None, check=True, extra_env=None):
    env = environment(config)
    if extra_env:
        env.update(extra_env)
    try:
        result = subprocess.run(args, cwd=cwd, env=env, input=data,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Error(f"command failed: {shlex.join(map(str, args))}: {exc}") from exc
    if check and result.returncode:
        if capture:
            sys.stderr.write(result.stderr.decode(errors="replace"))
        raise Error(f"command exited {result.returncode}: {shlex.join(map(str, args))}")
    return result


def git(config, repo, *args, capture=True, data=None, check=True, extra_env=None):
    return command(config, [config["git"], *SAFE_GIT, "-C", str(repo), *args],
                   capture=capture, data=data, check=check, extra_env=extra_env, timeout=30)


def git_text(config, repo, *args):
    return git(config, repo, *args).stdout.decode().strip()


def private_directories():
    for directory in (RUN, STATE, STATE / "candidates"):
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise Error(f"{directory} must be a real root-owned 0700 directory")


@contextlib.contextmanager
def operation_lock():
    private_directories()
    with (RUN / "apply.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Error("another apply/confirm operation is busy; do not overlap requests") from exc
        yield


def save_candidate(candidate, pending=False):
    atomic_json(RUN / "candidate.json", candidate)
    if pending:
        atomic_json(STATE / "pending.json", candidate)


def candidate_state():
    return read_json(STATE / "pending.json") or read_json(RUN / "candidate.json")


def token_path(candidate):
    name = candidate["module_hash"]
    if not re.fullmatch(r"[0-9a-f]{64}", name):
        raise Error("invalid candidate module digest")
    return RUN / ("confirmed-" + name)


def revoke(candidate):
    if candidate:
        token_path(candidate).unlink(missing_ok=True)


def epoch():
    return read_json(RUN / "recovery-epoch.json")


def systemctl(config, *args, check=True):
    return command(config, [config["systemctl"], *args], capture=True, timeout=10, check=check)


def active(config, unit):
    result = systemctl(config, "show", unit, "--property=ActiveState", "--value", check=False)
    if result.returncode:
        raise Error(f"cannot inspect systemd unit {unit}: {result.stderr.decode(errors='replace')}")
    return result.stdout.decode().strip() in ("active", "activating", "deactivating", "reloading")


def recovery_quiet(config):
    for suffix in (".timer", ".service"):
        unit = config["unit"] + suffix
        if active(config, unit):
            return False
        job = systemctl(config, "show", unit, "--property=Job", "--value").stdout.decode().strip()
        if job and job not in ("0", "0 /"):
            return False
    return not (RUN / "recovering.json").exists()


LOADER = """# Human-owned: do not edit this file from the agent account.
{ ... }:
let
  entries = builtins.readDir ./.;
  names = builtins.filter
    (name: name != "default.nix" && entries.${name} == "regular"
      && builtins.match ".*\\\\.nix" name != null)
    (builtins.attrNames entries);
in
{
  imports = map (name: ./. + "/${name}") names;
}
"""


def protected(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise Error(f"trusted path must be root-owned and not writable by the agent: {path}")


def setup(config):
    root_required()
    host, flake, agent = config["host"], config["flake"], config["agent"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", host or ""):
        raise Error("set services.aether.host to the explicit nixosConfigurations key")
    if not agent:
        raise Error("set services.aether.agentUser and follow docs/HARDENING.md first")
    try:
        account = pwd.getpwnam(agent)
    except KeyError as exc:
        raise Error("services.aether.agentUser does not name an existing account") from exc
    if account.pw_uid == 0:
        raise Error("the configured agent must be a separate, non-root account")
    if not flake.startswith("/") or any(x in flake for x in ("#", "?", "\n", "\r")):
        raise Error("services.aether.flake must be an absolute local directory without #, ? or line breaks")
    repo = Path(flake)
    if str(repo.resolve(strict=True)) != str(repo):
        raise Error("the configured flake path must be canonical, without symlink components")
    for ancestor in (repo, *repo.parents):
        protected(ancestor)
    for name in ("flake.nix", "flake.lock", ".git"):
        protected(repo / name)
    if not (repo / ".git").is_dir():
        raise Error("use a standalone Git checkout, not a linked .git file")
    proposals = repo / "hosts" / host / "modules/agent"
    for parent in (proposals.parent, proposals.parent.parent, proposals.parent.parent.parent):
        protected(parent)
    info = proposals.lstat()
    groups = os.getgrouplist(agent, account.pw_gid)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or
            not info.st_mode & stat.S_ISVTX or not info.st_mode & stat.S_IWGRP or
            info.st_mode & stat.S_IWOTH or info.st_gid not in groups):
        raise Error("proposal directory must be root-owned, sticky and group-writable only by the configured agent group")
    protected(proposals / "default.nix")
    if (proposals / "default.nix").read_text() != LOADER:
        raise Error("install the exact protected auto-importer from examples/hosts/vps/modules/agent/default.nix")
    for directory, dirs, files in os.walk(repo):
        here = Path(directory)
        if here == proposals:
            dirs[:] = []
            continue
        for name in dirs + files:
            path = here / name
            if path == proposals or (here == repo and name.startswith("result")):
                continue
            protected(path)
            if name == ".gitattributes" and path.read_text().strip():
                raise Error("custom Git attributes/filters are unsupported in a privileged managed repository")
    if (repo / ".git/info/attributes").exists() and (repo / ".git/info/attributes").read_text().strip():
        raise Error("custom Git info/attributes are unsupported")
    entries = git(config, repo, "config", "--local", "--no-includes", "--null", "--list").stdout
    for entry in entries.decode().split("\0"):
        if not entry:
            continue
        key, _, value = entry.partition("\n")
        ordinary = key in {
            "core.repositoryformatversion", "core.filemode", "core.bare",
            "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
            "user.name", "user.email",
        } or re.fullmatch(r"(remote\.[^.]+\.(url|fetch)|branch\.[^.]+\.(remote|merge))", key)
        if not ordinary or "\n" in value:
            raise Error(f"unsupported local Git configuration: {key}")
    if git(config, repo, "ls-files", "--error-unmatch", "result", check=False).returncode == 0:
        raise Error("result is tracked; a human must remove it from the index and ignore it first")
    git_text(config, repo, "symbolic-ref", "--quiet", "HEAD")
    return repo, proposals, account.pw_uid


def stable_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise Error(f"proposal must be a regular non-hardlinked file: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read()
        after = os.fstat(descriptor)
        stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if stamp(before) != stamp(after):
            raise Error(f"source changed while reading {path}; retry after edits finish")
        return data, stamp(after)
    finally:
        os.close(descriptor)


def source_view(config, repo, proposals):
    prefix = proposals.relative_to(repo).as_posix() + "/"
    changed = set()
    for args in (("diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--no-renames", "HEAD"),
                 ("diff", "--cached", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--no-renames"),
                 ("ls-files", "--others", "--exclude-standard", "-z")):
        changed.update(x.decode() for x in git(config, repo, *args).stdout.split(b"\0") if x)
    for name in changed:
        suffix = name.removeprefix(prefix)
        if (not name.startswith(prefix) or suffix == "default.nix" or
                not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.nix", suffix)):
            raise Refusal(f"unexpected dirty path {name}; only this host's proposal .nix files may change")
    contents, identities = {}, []
    for path in sorted(proposals.iterdir()):
        if path.name == "default.nix":
            continue
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.nix", path.name):
            if path.relative_to(repo).as_posix() in changed:
                raise Refusal(f"unsupported proposal path {path}")
            protected(path)
            continue
        data, identity = stable_file(path)
        relative = path.relative_to(repo).as_posix()
        contents[relative] = data
        identities.append((relative, hashlib.sha256(data).hexdigest(), identity))
    sources = []
    for name in sorted(changed):
        if name in contents:
            sources.append((name, contents[name].decode("utf-8")))
        # A removal or staged-only change must retain its old risk floor.
        for revision in ("HEAD:" + name, ":" + name):
            old = git(config, repo, "show", revision, check=False)
            if old.returncode == 0:
                sources.append((revision, old.stdout.decode("utf-8")))
    return {
        "head": git_text(config, repo, "rev-parse", "HEAD"),
        "contents": contents, "changed": sorted(changed), "sources": sources,
        "fingerprint": digest(identities),
        "module_hash": digest([(name, data.hex()) for name, data in sorted(contents.items())]),
    }


def show_risk(risk):
    print(f"aether: effective risk R{risk.level}", flush=True)
    for reason in risk.reasons:
        print(f"  {reason}", flush=True)


def transfer_tree(config, source, destination, tree):
    pack = git(config, source, "pack-objects", "--stdout", "--revs",
               data=(tree + "\n").encode()).stdout
    git(config, destination, "unpack-objects", "-r", data=pack)
    git(config, destination, "read-tree", tree)


def unchanged(config, candidate):
    repo, proposals, _ = setup(config)
    view = source_view(config, repo, proposals)
    return (view["head"] == candidate["head"] and
            view["fingerprint"] == candidate["fingerprint"] and
            config["host"] == candidate["host"] and config["flake"] == candidate["flake"])


def frozen_candidate(config, repo, proposals, view, risk, caller):
    identity = uuid.uuid4().hex
    folder = STATE / "candidates" / identity
    folder.mkdir(mode=0o700)
    source = folder / "source"
    git(config, repo, "clone", "--quiet", "--no-hardlinks", "--no-checkout", str(repo), str(source))
    git(config, source, "checkout", "--quiet", "--detach", view["head"])
    frozen_proposals = source / proposals.relative_to(repo)
    for path in frozen_proposals.iterdir():
        if path.name != "default.nix" and path.suffix == ".nix":
            path.unlink()
    for name, data in view["contents"].items():
        (source / name).write_bytes(data)
    git(config, source, "add", "-A")
    tree = git_text(config, source, "write-tree")
    tracked = set(git(config, source, "ls-files", "-z").stdout.decode().split("\0"))
    if not set(view["contents"]).issubset(tracked):
        raise Error("Git ignore rules hide proposed modules; fix the trusted baseline")
    candidate = {
        "id": identity, "phase": "prepared", "head": view["head"], "tree": tree,
        "fingerprint": view["fingerprint"], "module_hash": view["module_hash"],
        "changed": view["changed"], "host": config["host"], "flake": config["flake"],
        "boot": boot_id(), "proposer": caller, "risk": risk.level,
        "reasons": risk.reasons, "boot_only": risk.boot_only, "folder": str(folder),
        "epoch": epoch(),
    }
    if not unchanged(config, candidate):
        raise Error("source changed while freezing the candidate; nothing will be activated")
    transfer_tree(config, source, repo, tree)
    print(f"aether: frozen candidate {identity}; checking and building its exact tree", flush=True)
    command(config, [config["nix"], "flake", "check", "--no-update-lock-file",
                     "--no-write-lock-file", str(source)], cwd=source)
    command(config, [config["rebuild"], "build", "--flake", f"{source}#{config['host']}",
                     "--no-update-lock-file"], cwd=source)
    candidate["system"] = canonical_system(source / "result")
    candidate["baseline"] = canonical_system("/run/current-system")
    command(config, [config["nix_store"], "--add-root", str(folder / "baseline"),
                     "--indirect", "--realise", candidate["baseline"]], capture=True)
    diff = command(config, [config["nix"], "store", "diff-closures",
                            "/run/current-system", "./result"], cwd=source, capture=True)
    output = diff.stdout.decode()
    print(output, end="" if output.endswith("\n") else "\n", flush=True)
    candidate["diff"] = output
    sized = effective_risk([], candidate["risk"], output)
    candidate["risk"] = sized.level
    for reason in sized.reasons:
        if reason not in candidate["reasons"]:
            candidate["reasons"].append(reason)
    show_risk(Risk(candidate["risk"], candidate["reasons"], candidate["boot_only"]))
    if not unchanged(config, candidate):
        raise Error("source changed during the build; the frozen build is not approval to activate")
    result = repo / "result"
    temporary = repo / (".aether-result-" + identity)
    temporary.symlink_to(candidate["system"])
    os.replace(temporary, result)
    save_candidate(candidate)
    return candidate


def console_recovery(candidate):
    target = candidate["baseline"]
    print("aether: recovery required. From the root console, not the agent account:", file=sys.stderr)
    print(f"  nix-env --profile {PROFILE} --set {shlex.quote(target)}", file=sys.stderr)
    print("  systemd-run --scope --collect " +
          shlex.quote(target + "/bin/switch-to-configuration") + " switch", file=sys.stderr)
    print("Then remove only the failed request's module and run aether-apply build.", file=sys.stderr)


def invalidate_pending(candidate, reason):
    revoke(candidate)
    candidate["phase"] = "recovery-required"
    candidate["error"] = reason
    save_candidate(candidate, pending=True)
    console_recovery(candidate)
    raise Error(reason)


def finish(candidate):
    revoke(candidate)
    (STATE / "pending.json").unlink(missing_ok=True)
    (RUN / "candidate.json").unlink(missing_ok=True)
    (RUN / "rollback-target").unlink(missing_ok=True)
    folder = Path(candidate["folder"])
    if folder.parent != STATE / "candidates" or not re.fullmatch(r"[0-9a-f]{32}", folder.name):
        raise Error("invalid transaction cleanup path")
    shutil.rmtree(folder)


def recovery_build(config, repo, proposals, view, risk, caller, pending):
    if (not recovery_quiet(config) or
            canonical_system("/run/current-system") != pending["baseline"]):
        console_recovery(pending)
        raise Error("rollback has not completed to the captured known-good system")
    candidate = frozen_candidate(config, repo, proposals, view, risk, caller)
    if candidate["system"] != canonical_system("/run/current-system"):
        revoke(pending)
        save_candidate(pending, pending=True)
        raise Error("repo and running system DIVERGE; no commit, activation or new request is allowed")
    finish(pending)
    # The fresh build stays available, but equality is not permission to retry.
    save_candidate(candidate)
    print("repo matches running system")
    print("aether: recovery complete; this does not approve another attempt")


def token_context(candidate):
    return {key: candidate[key] for key in (
        "id", "module_hash", "tree", "system", "head", "host", "flake", "boot", "proposer")}


def confirm(config):
    caller = principal()
    _, _, agent = setup(config)
    if caller == agent:
        raise Error("the agent principal cannot confirm; use a DIFFERENT human account")
    with operation_lock():
        candidate = read_json(STATE / "pending.json")
        if not candidate or candidate["phase"] != "awaiting-human":
            raise Error("there is no successfully tested R3 candidate awaiting human confirmation")
        if caller == candidate["proposer"]:
            raise Error("the proposing principal cannot confirm; use a DIFFERENT human account")
        if (candidate["boot"] != boot_id() or not unchanged(config, candidate) or
                candidate["epoch"] != epoch() or
                canonical_system("/run/current-system") != candidate["system"]):
            invalidate_pending(candidate, "stale/edited candidate or rollback; confirmation refused")
        print("aether: running this command attests that you opened a FRESH second SSH session,"
              " checked access and reviewed this exact candidate.", flush=True)
        print(f"aether: {candidate['module_hash']} -> {candidate['system']}", flush=True)
        # disarm stops the timer; it never stops a recovery service already firing.
        command(config, [config["disarm"]], timeout=20)
        if (not recovery_quiet(config) or candidate["epoch"] != epoch() or
                not unchanged(config, candidate) or
                canonical_system("/run/current-system") != candidate["system"]):
            invalidate_pending(candidate, "candidate changed or recovery raced disarming; no token written")
        candidate["phase"] = "confirmed"
        candidate["human"] = caller
        save_candidate(candidate, pending=True)
        atomic_json(token_path(candidate), token_context(candidate))
        print("aether: human confirmation recorded, timer disarmed; agent may switch this exact candidate once")


def apply(config, arguments):
    parser = argparse.ArgumentParser(prog="aether-apply", allow_abbrev=False)
    parser.add_argument("verb", choices=("build", "test", "switch"))
    parser.add_argument("--host", action="append", default=[])
    parser.add_argument("--risk", choices=("R1", "R2", "R3", "R4"), action="append", default=[])
    args = parser.parse_args(arguments)
    if len(args.host) > 1 or len(args.risk) > 1:
        raise Error("options may be specified only once")
    caller = principal()
    repo, proposals, agent = setup(config)
    if caller not in (agent, 0):
        raise Error("apply is reserved for the configured agent or console root")
    if args.host and args.host[0] != config["host"]:
        raise Error("--host must equal services.aether.host; privileged retargeting is not allowed")
    view = source_view(config, repo, proposals)
    declared = int(args.risk[0][1:]) if args.risk else 1
    try:
        risk = effective_risk(view["sources"], declared)
        if declared == 4:
            raise Refusal("model-declared R4")
    except Refusal as exc:
        print(f"aether: R4/manual refusal: {exc}", file=sys.stderr)
        for name in view["changed"]:
            print(f"  review module: {name}", file=sys.stderr)
        print(f"  console review: git -C {shlex.quote(str(repo))} diff --no-ext-diff HEAD", file=sys.stderr)
        print("  console build after human review: nixos-rebuild build --flake " +
              shlex.quote(f"{repo}#{config['host']}") + " --no-update-lock-file", file=sys.stderr)
        print("No staging, build or activation was performed. A human must review and apply"
              " from the console; see docs/HARDENING.md.", file=sys.stderr)
        raise
    show_risk(risk)
    with operation_lock():
        previous = candidate_state()
        pending = read_json(STATE / "pending.json")
        if pending:
            if pending["phase"] in ("testing", "switching") and active(config, f"aether-apply-{pending['id']}.scope"):
                raise Error("the detached activation worker is still busy")
            if pending["boot"] != boot_id():
                revoke(pending)
                pending["phase"] = "recovery-required"
                pending["error"] = "reboot invalidated the pending transaction"
                save_candidate(pending, pending=True)
            if pending["phase"] == "recovery-required":
                if args.verb != "build":
                    raise Error("recovery requires a fresh aether-apply build equal to the running system")
                recovery_build(config, repo, proposals, view, risk, caller, pending)
                return
            if not unchanged(config, pending):
                invalidate_pending(pending, "source changed after test; confirmation revoked")
            if pending["phase"] in ("testing", "switching"):
                invalidate_pending(pending, "activation was interrupted without a completion receipt")
        if previous and previous["boot"] == boot_id() and unchanged(config, previous):
            candidate = previous
            candidate["risk"] = max(candidate["risk"], risk.level)
            show_risk(Risk(candidate["risk"], candidate["reasons"], candidate["boot_only"]))
            print(candidate["diff"], end="" if candidate["diff"].endswith("\n") else "\n")
        else:
            if not recovery_quiet(config):
                raise Error("an existing timer or recovery is active; no new candidate may be built")
            candidate = frozen_candidate(config, repo, proposals, view, risk, caller)
        if args.verb == "build":
            print(f"aether: built {candidate['system']}; activates nothing")
            return
        if candidate["boot_only"]:
            raise Refusal("boot/kernel changes cannot use test or switch; a human must use boot and reboot")
        if candidate["risk"] >= 3 and args.verb == "switch":
            token = read_json(token_path(candidate))
            if (candidate["phase"] != "confirmed" or token != token_context(candidate)
                    or not recovery_quiet(config)
                    or candidate["epoch"] != epoch()
                    or canonical_system("/run/current-system") != candidate["system"]):
                raise Error("R3 switch requires test, a DIFFERENT human's aether-confirm, and successful disarm")
            revoke(candidate)
        elif pending and not (candidate["phase"] == "tested" and args.verb == "switch"):
            raise Error("a transaction is already pending; confirm/switch it or complete recovery")
        if not unchanged(config, candidate) or candidate["epoch"] != epoch():
            raise Error("candidate/source changed before activation")
        candidate["expected_running"] = (
            candidate["system"] if candidate["phase"] in ("tested", "confirmed")
            else candidate["baseline"]
        )
        if canonical_system("/run/current-system") != candidate["expected_running"]:
            raise Error("running system changed since preparation; rebuild/review a fresh candidate")
        candidate["phase"] = "testing" if args.verb == "test" else "switching"
        candidate["verb"] = args.verb
        save_candidate(candidate, pending=True)
        launch_worker(config, candidate)


def launch_worker(config, candidate):
    log = Path(candidate["folder"]) / "activation.log"
    args = [
        config["systemd_run"], "--scope", "--collect", "--quiet",
        "--unit=aether-apply-" + candidate["id"], config["python"], "-I",
        config["script"], config["config"], "worker", candidate["id"],
    ]
    with log.open("w+b") as stream:
        child = subprocess.Popen(args, env=environment(config), stdin=subprocess.DEVNULL,
                                 stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        status = child.wait()
        stream.seek(0)
        print(stream.read().decode(errors="replace"), end="")
    pending = read_json(STATE / "pending.json")
    if status or (pending and pending["phase"] == "recovery-required"):
        raise Error("detached activation did not complete successfully; inspect aether-status and recovery output")


def request_recovery(config, candidate, reason):
    revoke(candidate)
    candidate["phase"] = "recovery-required"
    candidate["error"] = reason
    save_candidate(candidate, pending=True)
    (RUN / "rollback-target").write_text(candidate["baseline"] + "\n")
    os.chmod(RUN / "rollback-target", 0o600)
    print(f"aether: ERROR: {reason}; requesting independent recovery", file=sys.stderr, flush=True)
    command(config, [config["systemd_run"], "--collect",
                     "--unit=aether-recover-" + candidate["id"], *shlex.split(config["rollback"])],
            timeout=10)


def commit_candidate(config, candidate):
    repo = Path(config["flake"])
    if not unchanged(config, candidate):
        raise Error("source changed during activation; refusing to commit")
    if candidate["tree"] == git_text(config, repo, "rev-parse", candidate["head"] + "^{tree}"):
        return
    names = ", ".join(Path(name).stem for name in candidate["changed"])
    message = f"Apply Aether: {names}\n\nRisk R{candidate['risk']}; activated {candidate['system']}.\n"
    identity = {"GIT_AUTHOR_NAME": "Aether", "GIT_AUTHOR_EMAIL": "aether@localhost",
                "GIT_COMMITTER_NAME": "Aether", "GIT_COMMITTER_EMAIL": "aether@localhost"}
    commit = git(config, repo, "commit-tree", candidate["tree"], "-p", candidate["head"],
                 "-m", message, extra_env=identity).stdout.decode().strip()
    git(config, repo, "update-ref", "HEAD", commit, candidate["head"])
    print(f"aether: committed exact activated tree {commit}", flush=True)


def worker(config, identity):
    root_required()
    candidate = read_json(STATE / "pending.json")
    if not re.fullmatch(r"[0-9a-f]{32}", identity) or not candidate or candidate["id"] != identity:
        raise Error("no matching private activation transaction")
    if candidate["phase"] not in ("testing", "switching"):
        raise Error("transaction is not awaiting an activation worker")
    try:
        if not unchanged(config, candidate) or candidate["epoch"] != epoch():
            raise Error("source or recovery epoch changed before worker activation")
        if canonical_system("/run/current-system") != candidate["expected_running"]:
            raise Error("running system changed before worker activation")
        verb = candidate["verb"]
        if candidate["risk"] >= 3 and verb == "test":
            command(config, [config["arm"]], timeout=20)
            if ((RUN / "rollback-target").read_text().strip() != candidate["baseline"] or
                    not active(config, config["unit"] + ".timer")):
                raise Error("arming did not establish the expected pin and live timer")
        else:
            if not recovery_quiet(config):
                raise Error("timer/recovery must be disarmed before this activation")
            (RUN / "rollback-target").write_text(candidate["baseline"] + "\n")
            os.chmod(RUN / "rollback-target", 0o600)
        if candidate["epoch"] != epoch():
            raise Error("recovery started before activation")
        if verb == "switch":
            command(config, [config["nix_env"], "--profile", str(PROFILE), "--set", candidate["system"]])
        candidate["activation_started"] = True
        save_candidate(candidate, pending=True)
        command(config, [candidate["system"] + "/bin/switch-to-configuration", verb])
        if (candidate["epoch"] != epoch() or not unchanged(config, candidate) or
                canonical_system("/run/current-system") != candidate["system"]):
            raise Error("activation did not preserve the reviewed candidate/context")
        if verb == "switch":
            if canonical_system(PROFILE) != candidate["system"] or not recovery_quiet(config):
                raise Error("final system profile or timer state is not safe to commit")
            commit_candidate(config, candidate)
            # Keep the log open for the caller while removing the private checkout.
            print(f"aether: switched {candidate['system']} and completed the transaction", flush=True)
            finish(candidate)
        else:
            candidate["phase"] = "awaiting-human" if candidate["risk"] >= 3 else "tested"
            save_candidate(candidate, pending=True)
            print(f"aether: tested {candidate['system']}; no commit", flush=True)
            if candidate["risk"] >= 3:
                print("aether: stop. A DIFFERENT human must open a fresh SSH session and run aether-confirm.", flush=True)
    except (Error, OSError) as exc:
        if candidate.get("activation_started") or (
                candidate["verb"] == "switch" and canonical_system(PROFILE) != candidate["baseline"]):
            request_recovery(config, candidate, str(exc))
        else:
            revoke(candidate)
            candidate["phase"] = "recovery-required"
            candidate["error"] = str(exc)
            save_candidate(candidate, pending=True)
            print("aether: ERROR: no candidate activation was permitted; recover with aether-apply build",
                  file=sys.stderr, flush=True)
        raise


def recovery_begin(systemctl_path):
    root_required()
    private_directories()
    atomic_json(RUN / "recovery-epoch.json", uuid.uuid4().hex)
    atomic_json(RUN / "recovering.json", True)
    candidate = candidate_state()
    if not candidate:
        return
    revoke(candidate)
    identity = candidate.get("id", "")
    if not re.fullmatch(r"[0-9a-f]{32}", identity):
        raise Error("invalid recorded apply scope; recovery activation must still proceed")
    unit = f"aether-apply-{identity}.scope"
    # Never acquire apply.lock: an interrupted worker may still own it.
    try:
        subprocess.run([systemctl_path, "kill", "--signal=KILL", unit],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
        deadline = time.monotonic() + 5
        while True:
            result = subprocess.run([systemctl_path, "show", unit, "--property=ActiveState", "--value"],
                                    capture_output=True, timeout=5, check=False)
            if result.returncode == 0 and result.stdout.strip() not in (b"active", b"activating"):
                break
            if time.monotonic() >= deadline:
                raise Error(f"apply scope {unit} did not stop; still attempting recovery")
            time.sleep(0.1)
    finally:
        candidate["phase"] = "recovery-required"
        candidate["error"] = "rollback invalidated the transaction"
        save_candidate(candidate, pending=True)


def recovery_finish(target, status):
    root_required()
    candidate = candidate_state()
    if candidate:
        candidate["phase"] = "recovery-required"
        candidate["recovered"] = status == 0
        candidate["recovery_target"] = target
        save_candidate(candidate, pending=True)
    (RUN / "recovering.json").unlink(missing_ok=True)


def show_status():
    candidate = candidate_state()
    if candidate:
        print(f"apply phase: {candidate['phase']}")
        print(f"candidate: {candidate['module_hash']}")
        print(f"risk: R{candidate['risk']}")
        print(f"built system: {candidate.get('system', 'not built')}")
        if candidate.get("error"):
            print(f"apply error: {candidate['error']}")
        if candidate["boot"] != boot_id():
            print("recovery required: reboot invalidated this transaction")


def main():
    try:
        if len(sys.argv) >= 2 and sys.argv[1] == "recovery-begin":
            recovery_begin(sys.argv[2])
            return
        if len(sys.argv) >= 2 and sys.argv[1] == "recovery-finish":
            recovery_finish(sys.argv[2], int(sys.argv[3]))
            return
        if len(sys.argv) == 2 and sys.argv[1] == "status":
            show_status()
            return
        if len(sys.argv) == 2 and sys.argv[1] == "revoke":
            root_required()
            revoke(candidate_state())
            return
        config = json.loads(Path(sys.argv[1]).read_text())
        config["config"] = sys.argv[1]
        operation, arguments = sys.argv[2], sys.argv[3:]
        if operation == "apply":
            apply(config, arguments)
        elif operation == "confirm" and not arguments:
            confirm(config)
        elif operation == "worker" and len(arguments) == 1:
            worker(config, arguments[0])
        elif operation == "index-preflight" and not arguments:
            setup(config)
        else:
            raise Error("unsupported helper arguments")
    except (Error, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"aether: ERROR: {exc}", file=sys.stderr, flush=True)
        sys.exit(4 if isinstance(exc, Refusal) else 1)


if __name__ == "__main__":
    main()
