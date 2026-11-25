#!/bin/bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage: spm-install

Run inside a project that keeps versions.json at its root. The command may be
started from the project root or from any directory below it.

It clones the dependencies listed in versions.json into ThirdParty/, points
them at each other through local paths, then writes lock.json next to
versions.json and the SwiftPM mirrors.json of the Xcode project.
USAGE
}

if [ "$#" -gt 0 ]; then
case "$1" in
-h|--help)
usage
exit 0
;;
*)
usage >&2
exit 2
;;
esac
fi

# The project is the nearest directory, from here upwards, that owns versions.json.
root="$PWD"
while [ ! -f "$root/versions.json" ]; do
parent="$(dirname "$root")"
if [ "$parent" = "$root" ]; then
echo "spm-install: no versions.json in $PWD or any parent directory" >&2
exit 1
fi
root="$parent"
done

manifest="$root/versions.json"
vendor="$root/ThirdParty"
lock="$root/lock.json"
generated_mirrors="$root/.swiftpm/configuration/mirrors.json"

python3 - "$manifest" "$vendor" "$lock" "$generated_mirrors" "$root" <<'PY'
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import urllib.parse

manifest_path, vendor, lock_path, generated_mirrors_path, repo_root = sys.argv[1:]

use_color = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PROGRESS = re.compile(
    r"(?:remote:\s*)?(Enumerating objects|Counting objects|Compressing objects|Receiving objects|Resolving deltas):\s+(\d+)%"
    r"(?:\s+\(([^)]+)\))?(?:,\s*([^\r\n]+))?"
)
SPEED = re.compile(r"(\d+(?:\.\d+)?\s*[KMGT]?i?B/s)")


def paint(message, color):
    if not use_color:
        return message
    return f"{color}{message}{RESET}"


def ok(message):
    print(paint(message, GREEN), flush=True)


def fail(message):
    print(paint(message, RED), file=sys.stderr, flush=True)


class CommandError(RuntimeError):
    pass


class DownloadStatus:
    def __init__(self):
        self.label = None
        self.last = ""
        self.stage = None
        self.percent = None
        self.tty = sys.stdout.isatty()

    def start(self, label):
        self.finish()
        self.label = label
        self.last = ""
        self.stage = None
        self.percent = None
        self._render(f"downloading {label}")

    def observe(self, text):
        if not self.label:
            return
        line = ANSI.sub("", text).strip()
        match = PROGRESS.search(line)
        if not match:
            return
        stage = match.group(1).lower()
        percent = int(match.group(2))
        counts = match.group(3)
        tail = match.group(4) or ""
        if not self.tty and stage == self.stage and percent != 100 and self.percent is not None:
            if percent // 10 == self.percent // 10:
                return
        self.stage = stage
        self.percent = percent
        speed_match = SPEED.search(tail)
        speed = f"  {speed_match.group(1)}" if speed_match else ""
        detail = f" ({counts})" if counts else ""
        self._render(f"downloading {self.label}  {stage} {percent}%{detail}{speed}")

    def _render(self, message):
        shown = paint(message, YELLOW)
        if self.tty:
            pad = max(0, len(self.last) - len(message))
            print(f"\r{shown}{' ' * pad}", end="", flush=True)
        elif message != self.last:
            print(shown, flush=True)
        self.last = message

    def finish(self):
        if self.label and self.tty and self.last:
            print(flush=True)
        self.label = None
        self.last = ""
        self.stage = None
        self.percent = None


status = DownloadStatus()


def stop(message):
    status.finish()
    fail(message)
    raise SystemExit(1)


with open(manifest_path, encoding="utf-8") as handle:
    direct_deps = json.load(handle)["dependencies"]

# Earlier versions kept the lock inside the ignored vendor directory.
legacy_lock_path = os.path.join(vendor, "lock.json")
if not os.path.isfile(lock_path) and os.path.isfile(legacy_lock_path):
    os.replace(legacy_lock_path, lock_path)
    ok(f"moved {legacy_lock_path} to {lock_path}")

previous = {"dependencies": [], "transitive": []}
if os.path.isfile(lock_path):
    with open(lock_path, encoding="utf-8") as handle:
        previous = json.load(handle)


def run(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise CommandError(detail or f"command failed: {' '.join(args)}")


def run_transfer(args, cwd=None):
    command = list(args)
    if command and command[0] == "git" and "--progress" not in command:
        command.insert(2, "--progress")
    process = subprocess.Popen(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stderr_lines = []

    def read_stderr():
        pending = ""
        while True:
            chunk = process.stderr.read(4096)
            if chunk == "":
                break
            pending += chunk
            parts = re.split(r"[\r\n]", pending)
            pending = parts.pop()
            for line in parts:
                line = line.strip()
                if not line:
                    continue
                stderr_lines.append(line)
                status.observe(line)
        if pending.strip():
            line = pending.strip()
            stderr_lines.append(line)
            status.observe(line)

    reader = threading.Thread(target=read_stderr)
    reader.start()
    stdout = process.stdout.read()
    code = process.wait()
    reader.join()
    if code != 0:
        detail = "\n".join(stderr_lines).strip() or (stdout or "").strip()
        raise CommandError(detail or f"command failed: {' '.join(command)}")


def capture(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise CommandError(detail or f"command failed: {' '.join(args)}")
    return result.stdout.strip()


def validate_name(name):
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        stop(f"invalid dependency name: {name}")


def normalize_repository(url):
    return url.rstrip("/").removesuffix(".git").lower()


def repository_basename(url):
    text = url.strip().split("?", 1)[0].split("#", 1)[0].rstrip("/")
    name = text.rsplit("/", 1)[-1]
    if name.lower().endswith(".git"):
        name = name[:-4]
    return name


def repository_url_forms(url):
    forms = [url]
    if not url.startswith(("https://", "http://")):
        return forms
    bare = url[:-4] if url.endswith(".git") else url
    sibling = bare if url.endswith(".git") else bare + ".git"
    if sibling not in forms:
        forms.append(sibling)
    return forms


def path_pinned_folders():
    manifest = os.path.join(repo_root, "Packages", "LuzkyMainKit", "Package.swift")
    pinned = {}
    if not os.path.isfile(manifest):
        return pinned
    with open(manifest, encoding="utf-8") as handle:
        text = handle.read()
    for match in re.finditer(r'path:\s*"\.\./ThirdParty/([^"]+)"', text):
        pinned[match.group(1).lower()] = match.group(1)
    return pinned


def folder_name_for_repository(repository):
    key = normalize_repository(repository)
    for dep in direct_deps:
        if normalize_repository(dep["repository"]) == key:
            return dep["name"]
    basename = repository_basename(repository)
    pinned = path_pinned_folders().get(basename.lower())
    if pinned:
        return pinned
    validate_name(basename)
    return basename


def matching_child(parent, name):
    if not os.path.isdir(parent):
        return None
    for entry in os.listdir(parent):
        if entry.lower() != name.lower():
            continue
        if os.path.isdir(os.path.join(parent, entry)):
            return entry
    return None


def rename_case_only(parent, current, desired):
    source = os.path.join(parent, current)
    target = os.path.join(parent, desired)
    temporary = os.path.join(parent, f".{desired}.rename")
    if os.path.lexists(temporary):
        stop(f"cannot rename {current} to {desired}: {temporary} already exists")
    os.rename(source, temporary)
    os.rename(temporary, target)


def migrate_transitive_folders():
    # Keep the repository basename's case. By-name dependencies compare that
    # case to the path SwiftPM loads, and Xcode lowercases mirrored file URLs.
    for item in previous.get("transitive", []):
        desired = folder_name_for_repository(item["repository"])
        current = matching_child(vendor, desired)
        if current and current != desired:
            rename_case_only(vendor, current, desired)
            ok(f"renamed {current} to {desired}")
        item["name"] = desired


def head_commit(dest):
    return capture(["git", "rev-parse", "HEAD"], cwd=dest)


def has_commit(dest):
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=dest,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def tag_commit(dest, tag_ref):
    return subprocess.check_output(
        ["git", "rev-parse", f"{tag_ref}^{{}}"],
        cwd=dest,
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def has_origin(dest):
    result = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=dest,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def remove_tree(dest):
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    elif os.path.lexists(dest):
        os.remove(dest)


def pinned_tag(dest, version):
    if not os.path.isdir(os.path.join(dest, ".git")) or not has_commit(dest):
        return None
    candidates = [version] if version.startswith("v") else [version, f"v{version}"]
    head = head_commit(dest)
    for candidate in candidates:
        try:
            if tag_commit(dest, f"refs/tags/{candidate}") == head:
                return candidate
        except subprocess.CalledProcessError:
            continue
    return None


def retain_pinned_tag(dest, version):
    if not is_revision(version):
        candidates = [version] if version.startswith("v") else [version, f"v{version}"]
        keep = None
        for candidate in candidates:
            try:
                if tag_commit(dest, f"refs/tags/{candidate}") == head_commit(dest):
                    keep = candidate
                    break
            except subprocess.CalledProcessError:
                continue
        if keep is None:
            keep = candidates[0]
            run(["git", "tag", "-f", keep, "HEAD"], cwd=dest)
        listed = capture(["git", "tag", "--list"], cwd=dest).splitlines()
        for name in listed:
            if name != keep:
                run(["git", "tag", "-d", name], cwd=dest)
    if has_origin(dest):
        run(["git", "remote", "remove", "origin"], cwd=dest)


def git_failure(detail):
    lines = [line.strip() for line in detail.splitlines() if line.strip()]
    reasons = [line for line in lines if line.startswith(("fatal:", "error:"))]
    if reasons:
        return "; ".join(reasons)
    if lines:
        return lines[-1]
    return "git gave no error output"


def checkout_tag(repository, dest, version, label=None):
    if pinned_tag(dest, version):
        return head_commit(dest)
    candidates = [version] if version.startswith("v") else [version, f"v{version}"]
    label = label or f"{os.path.basename(dest)} {version}"
    status.start(label)
    try:
        remove_tree(dest)
        tag = None
        failures = []
        for candidate in candidates:
            try:
                run_transfer(["git", "clone", "--depth", "1", "--branch", candidate, repository, dest])
            except CommandError as exc:
                failures.append(f"{candidate}: {git_failure(str(exc))}")
                remove_tree(dest)
                continue
            try:
                if tag_commit(dest, f"refs/tags/{candidate}") == head_commit(dest):
                    tag = candidate
                    break
            except subprocess.CalledProcessError:
                pass
            failures.append(f"{candidate}: cloned, but it is not a tag")
            remove_tree(dest)
        if tag is None:
            detail = "\n".join(f"  {line}" for line in failures)
            stop(
                f"{os.path.basename(dest)}: could not check out {version} from {repository}\n"
                f"{detail}"
            )
        return head_commit(dest)
    finally:
        status.finish()


def checkout_revision(repository, dest, revision, label=None):
    if checkout_matches(dest, revision):
        return
    label = label or f"{os.path.basename(dest)} {revision[:12]}"
    status.start(label)
    try:
        remove_tree(dest)
        os.makedirs(dest, exist_ok=True)
        run(["git", "init"], cwd=dest)
        run(["git", "remote", "add", "origin", repository], cwd=dest)
        run_transfer(["git", "fetch", "--depth", "1", "origin", revision], cwd=dest)
        run(["git", "checkout", "--detach", "--force", "FETCH_HEAD"], cwd=dest)
        if head_commit(dest) != revision:
            stop(f"{dest}: expected commit {revision}, found {head_commit(dest)}")
    finally:
        status.finish()


def checkout_version(repository, dest, version, label=None):
    if is_revision(version):
        checkout_revision(repository, dest, version, label)
    else:
        checkout_tag(repository, dest, version, label)


LOCALIZATION_SUBJECT = "Use local dependency paths and submodule checkouts"


def upstream_commit(dest):
    # Localization commits exist only on this machine, so step back to the
    # commit that came from the remote.
    revision = "HEAD"
    while capture(["git", "log", "-1", "--format=%s", revision], cwd=dest) == LOCALIZATION_SUBJECT:
        revision += "^"
    return capture(["git", "rev-parse", revision], cwd=dest)


def checkout_matches(dest, version):
    if not os.path.isdir(os.path.join(dest, ".git")) or not has_commit(dest):
        return False
    if is_revision(version):
        return upstream_commit(dest) == version
    return pinned_tag(dest, version) is not None


def closure_is_current(dep):
    matched = [
        item for item in previous.get("dependencies", [])
        if item.get("name") == dep["name"] and item.get("resolved") is True
    ]
    if len(matched) != 1:
        return False
    current = matched[0]
    return current.get("repository") == dep["repository"] and current.get("version") == dep["version"]


def disk_matches(entries):
    for item in entries:
        if not checkout_matches(os.path.join(vendor, item["name"]), item["version"]):
            return False
    return True


def locked_version(repository):
    key = normalize_repository(repository)
    for item in previous.get("transitive", []):
        if normalize_repository(item["repository"]) == key:
            return item["version"]
    return None


def parse_version(text):
    if text.startswith("v"):
        text = text[1:]
    if "-" in text:
        return None
    parts = []
    for piece in text.split("."):
        if not piece.isdigit():
            return None
        parts.append(int(piece))
    return tuple(parts)


def version_less(left, right):
    size = max(len(left), len(right))
    left = left + (0,) * (size - len(left))
    right = right + (0,) * (size - len(right))
    return left < right


remote_tags = {}


def tags_for(repository):
    key = normalize_repository(repository)
    if key not in remote_tags:
        listing = capture(["git", "ls-remote", "--tags", repository])
        found = {}
        for line in listing.splitlines():
            sha, ref = line.split()
            if not ref.startswith("refs/tags/"):
                continue
            name = ref[len("refs/tags/"):]
            if name.endswith("^{}"):
                name = name[:-3]
            found[name] = sha
        remote_tags[key] = found
    return remote_tags[key]


def version_satisfies(version, requirement):
    if "revision" in requirement:
        return requirement["revision"][0] == version
    parsed = parse_version(version)
    if parsed is None:
        return False
    if "exact" in requirement:
        return parse_version(requirement["exact"][0]) == parsed
    if "range" in requirement:
        bounds = requirement["range"][0]
        lower = parse_version(bounds["lowerBound"])
        upper = parse_version(bounds["upperBound"])
        return (not version_less(parsed, lower)) and version_less(parsed, upper)
    if "branch" in requirement:
        return requirement["branch"][0] == version
    return False


def describe_requirement(requirement):
    if "exact" in requirement:
        return f"exact {requirement['exact'][0]}"
    if "range" in requirement:
        bounds = requirement["range"][0]
        return f"{bounds['lowerBound']} ..< {bounds['upperBound']}"
    if "revision" in requirement:
        return f"revision {requirement['revision'][0]}"
    if "branch" in requirement:
        return f"branch {requirement['branch'][0]}"
    return "unconstrained"


def select_for_requirements(repository, requirements):
    revisions = []
    branches = []
    for requirement in requirements:
        if "revision" in requirement:
            revisions.append(requirement["revision"][0])
        elif "branch" in requirement:
            branches.append(requirement["branch"][0])
    if revisions or branches:
        if len(set(revisions)) > 1 or len(set(branches)) > 1 or (revisions and branches):
            return None
        chosen = revisions[0] if revisions else branches[0]
        if all(version_satisfies(chosen, requirement) for requirement in requirements):
            return chosen
        return None
    best_name = None
    best_parsed = None
    for name in tags_for(repository):
        parsed = parse_version(name)
        if parsed is None:
            continue
        if not all(version_satisfies(name, requirement) for requirement in requirements):
            continue
        if best_parsed is None or version_less(best_parsed, parsed):
            best_parsed = parsed
            best_name = name
    return best_name


def choose_shared_package(items):
    urls = []
    for item in items:
        if item["repository"] not in urls:
            urls.append(item["repository"])
    versions = {item["version"] for item in items}
    if len(versions) == 1:
        chosen = dict(items[0])
        chosen["urls"] = urls
        return chosen
    if any("requirement" not in item for item in items):
        current = items[0]
        other = next(item for item in items if item["version"] != current["version"])
        stop(
            f"version conflict for {other['repository']}: "
            f"{current['via']} wants {current['version']}, {other['via']} wants {other['version']}"
        )
    requirements = [item["requirement"] for item in items]
    version = select_for_requirements(items[0]["repository"], requirements)
    if version is None:
        detail = ", ".join(
            f"{item['via']} requires {describe_requirement(item['requirement'])}"
            for item in items
        )
        stop(f"version conflict for {items[-1]['repository']}: {detail}")
    chosen = dict(items[0])
    chosen["version"] = version
    chosen["urls"] = urls
    vias = ", ".join(dict.fromkeys(item["via"] for item in items))
    ok(f"resolved {chosen['name']} {version} for {vias}")
    return chosen


def resolve_version(repository, requirement):
    # A locked version wins for as long as the manifest still accepts it.
    locked = locked_version(repository)
    if locked and version_satisfies(locked, requirement):
        return locked
    return select_version(repository, requirement)


def select_version(repository, requirement):
    if "exact" in requirement:
        return requirement["exact"][0]
    if "revision" in requirement:
        return requirement["revision"][0]
    if "branch" in requirement:
        return requirement["branch"][0]
    if "range" not in requirement:
        stop(f"unsupported requirement: {requirement}")
    bounds = requirement["range"][0]
    lower = parse_version(bounds["lowerBound"])
    upper = parse_version(bounds["upperBound"])
    best_name = None
    best_parsed = None
    for name in tags_for(repository):
        parsed = parse_version(name)
        if parsed is None:
            continue
        if version_less(parsed, lower) or not version_less(parsed, upper):
            continue
        if best_parsed is None or version_less(best_parsed, parsed):
            best_parsed = parsed
            best_name = name
    if best_name is None:
        stop(
            f"no tag in {bounds['lowerBound']} ..< {bounds['upperBound']} for {repository}"
        )
    return best_name


def used_dependencies(dest):
    name = os.path.basename(os.path.normpath(dest))
    manifest_path = os.path.join(dest, "Package.swift")
    if not os.path.isfile(manifest_path):
        stop(
            f"{name}: missing Package.swift at {manifest_path}. "
            "This checkout is not a Swift package, so swift package dump-package "
            "cannot read its dependencies."
        )
    try:
        dumped = capture(["swift", "package", "dump-package"], cwd=dest)
    except CommandError as exc:
        detail = str(exc).strip() or "swift package dump-package failed"
        stop(f"{name}: {detail} (directory: {dest})")
    manifest = json.loads(dumped)
    declared = {}
    for entry in manifest.get("dependencies", []):
        source = entry.get("sourceControl")
        if not source:
            continue
        info = source[0]
        remote = info.get("location", {}).get("remote")
        if not remote:
            continue
        identity = info["identity"]
        validate_name(identity)
        repository = remote[0]["urlString"]
        record = {
            "name": folder_name_for_repository(repository),
            "repository": repository,
            "version": resolve_version(repository, info["requirement"]),
            "requirement": info["requirement"],
        }
        declared[identity.lower()] = record
        alias = info.get("nameForTargetDependencyResolutionOnly")
        if alias:
            declared[alias.lower()] = record
    used = set()
    for target in manifest.get("targets", []):
        if target.get("type") == "test":
            continue
        for dependency in target.get("dependencies") or []:
            product = dependency.get("product")
            by_name = dependency.get("byName")
            if product and product[1]:
                used.add(product[1].lower())
            if by_name and by_name[0]:
                used.add(by_name[0].lower())
    seen = set()
    found = []
    for name in sorted(used):
        record = declared.get(name)
        if not record:
            continue
        key = normalize_repository(record["repository"])
        if key in seen:
            current = next(
                entry for entry in found
                if normalize_repository(entry["repository"]) == key
            )
            if not version_satisfies(current["version"], record["requirement"]):
                stop(
                    f"{record['repository']} {current['version']} does not satisfy "
                    f"a later requirement from {dest}"
                )
            continue
        seen.add(key)
        found.append(record)
    return found


def is_revision(value):
    return len(value) == 40 and all(character in "0123456789abcdef" for character in value.lower())


def collect_transitive(dest, via, folders_by_repository, seen=None):
    if seen is None:
        seen = set(folders_by_repository)
    found = []
    for item in used_dependencies(dest):
        key = normalize_repository(item["repository"])
        if key in folders_by_repository:
            direct_dest = os.path.join(vendor, folders_by_repository[key])
            expected = item["version"] if item["version"].startswith("v") else None
            tag_refs = [f"refs/tags/{item['version']}"]
            if expected is None:
                tag_refs.append(f"refs/tags/v{item['version']}")
            matched = False
            for tag_ref in tag_refs:
                try:
                    if tag_commit(direct_dest, tag_ref) == head_commit(direct_dest):
                        matched = True
                        break
                except subprocess.CalledProcessError:
                    continue
            if not matched:
                stop(
                    f"{item['repository']} checkout does not match {item['version']} required by {via}"
                )
            continue
        if key in seen:
            continue
        seen.add(key)
        child = os.path.join(vendor, item["name"])
        label = f"{item['name']} {item['version']} via {via}"
        if is_revision(item["version"]):
            checkout_revision(item["repository"], child, item["version"], label)
            commit = item["version"]
        else:
            commit = checkout_tag(item["repository"], child, item["version"], label)
        record = {
            "name": item["name"],
            "repository": item["repository"],
            "version": item["version"],
            "via": via,
            "requirement": item["requirement"],
        }
        ok(f"fetched {record['name']} {record['version']} {commit} via {via}")
        found.append(record)
        found.extend(collect_transitive(child, via, folders_by_repository, seen))
    return found


def parse_gitmodules(dest):
    path = os.path.join(dest, ".gitmodules")
    if not os.path.isfile(path):
        return []
    modules = []
    current = {}
    with open(path, encoding="utf-8", newline="") as handle:
        for raw in handle:
            line = raw.strip()
            if line.startswith("[submodule"):
                if current.get("path") and current.get("url"):
                    modules.append(current)
                current = {}
            elif line.startswith("path =") or line.startswith("path="):
                current["path"] = line.split("=", 1)[1].strip()
            elif line.startswith("url =") or line.startswith("url="):
                current["url"] = line.split("=", 1)[1].strip()
    if current.get("path") and current.get("url"):
        modules.append(current)
    return modules


def gitlink_sha(dest, path):
    try:
        line = capture(["git", "ls-tree", "HEAD", "--", path], cwd=dest)
    except CommandError:
        return None
    if "\t" not in line:
        return None
    meta, _found = line.split("\t", 1)
    parts = meta.split()
    if len(parts) < 3 or parts[1] != "commit":
        return None
    return parts[2]


def has_object(dest, revision):
    result = subprocess.run(
        ["git", "cat-file", "-e", f"{revision}^{{commit}}"],
        cwd=dest,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def is_ancestor(dest, ancestor, descendant):
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=dest,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def vendor_git_directories():
    found = []
    if not os.path.isdir(vendor):
        return found
    for entry in sorted(os.listdir(vendor)):
        dest = os.path.join(vendor, entry)
        if os.path.isdir(os.path.join(dest, ".git")):
            found.append(dest)
    return found


def vendor_directory(url):
    if not url or url.startswith("file:"):
        return None
    desired = folder_name_for_repository(url)
    return matching_child(vendor, desired)


def directory_for_url(url):
    if not url:
        return None
    if url.startswith("file:"):
        parsed = urllib.parse.urlparse(url.strip())
        raw = urllib.parse.unquote(parsed.path)
        if not raw:
            return None
        current = matching_child(vendor, os.path.basename(raw.rstrip("/")))
        if current:
            return os.path.join(vendor, current)
        if os.path.isdir(raw):
            return raw
        return None
    folder = vendor_directory(url)
    if not folder:
        return None
    return os.path.join(vendor, folder)


def ensure_object(dest, repository, revision, label):
    if has_object(dest, revision):
        return
    added_origin = False
    status.start(f"{label} {revision[:12]}")
    try:
        if not has_origin(dest):
            run(["git", "remote", "add", "origin", repository], cwd=dest)
            added_origin = True
        run_transfer(["git", "fetch", "--depth", "1", "origin", revision], cwd=dest)
        if not has_object(dest, revision):
            stop(f"{dest}: missing commit {revision}")
    finally:
        if added_origin and has_origin(dest):
            run(["git", "remote", "remove", "origin"], cwd=dest)
        status.finish()


def seed_submodule_sources():
    found = {}
    for item in previous.get("transitive", []):
        if item.get("via") != "submodule":
            continue
        name = item.get("name")
        repository = item.get("repository")
        if name and repository and not str(repository).startswith("file:"):
            found[name.lower()] = repository
    return found


def ensure_submodule_checkouts(remembered):
    seen = set()
    grew = True
    while grew:
        grew = False
        for dest in vendor_git_directories():
            for module in parse_gitmodules(dest):
                url = module["url"]
                if url.startswith("file:"):
                    continue
                marker = (os.path.normpath(dest), module["path"], url)
                if marker in seen:
                    continue
                sha = gitlink_sha(dest, module["path"])
                if not sha:
                    continue
                seen.add(marker)
                folder = folder_name_for_repository(url)
                validate_name(folder)
                existing = matching_child(vendor, folder)
                if existing is None:
                    child = os.path.join(vendor, folder)
                    checkout_revision(url, child, sha, f"{folder} {sha[:12]}")
                    if has_origin(child):
                        run(["git", "remote", "remove", "origin"], cwd=child)
                    existing = folder
                    grew = True
                else:
                    child = os.path.join(vendor, existing)
                    ensure_object(child, url, sha, existing)
                if has_object(child, sha):
                    run(["git", "update-ref", f"refs/vendor/{sha}", sha], cwd=child)
                remembered[existing.lower()] = url


def matching_paren(text, open_index):
    depth = 0
    in_string = False
    escape = False
    index = open_index
    while index < len(text):
        character = text[index]
        if in_string:
            if escape:
                escape = False
            elif character == "\\":
                escape = True
            elif character == '"':
                in_string = False
        else:
            if character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    return index
        index += 1
    return None


def matching_brace(text, open_index):
    depth = 0
    in_string = False
    escape = False
    index = open_index
    while index < len(text):
        character = text[index]
        if in_string:
            if escape:
                escape = False
            elif character == "\\":
                escape = True
            elif character == '"':
                in_string = False
        else:
            if character == '"':
                in_string = True
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return index
        index += 1
    return None


def iter_balanced_calls(text, prefix):
    start = 0
    while True:
        index = text.find(prefix, start)
        if index < 0:
            return
        line_start = text.rfind("\n", 0, index) + 1
        if "//" in text[line_start:index]:
            start = index + len(prefix)
            continue
        open_index = index + len(prefix) - 1
        end = matching_paren(text, open_index)
        if end is None:
            return
        yield index, end + 1
        start = end + 1


def excluded_ranges(text, spans):
    def contains(index):
        for start, end in spans:
            if start <= index < end:
                return True
        return False
    return contains


def vendored_urls_in(text):
    found = []
    seen = set()
    for match in re.finditer(r"https?://[^\s\"')]+", text):
        url = match.group(0).rstrip(".,")
        folder = vendor_directory(url)
        if not folder:
            continue
        key = normalize_repository(url)
        if key in seen:
            continue
        seen.add(key)
        found.append((url, folder))
    return found


def non_test_package_names(text):
    test_spans = list(iter_balanced_calls(text, ".testTarget("))
    excluded = excluded_ranges(text, test_spans)
    names = set()
    for match in re.finditer(r'package:\s*"([^"]+)"', text):
        if not excluded(match.start()):
            names.add(match.group(1).lower())
    for match in re.finditer(r'"([^"]+)"', text):
        if excluded(match.start()):
            continue
        value = match.group(1)
        if "://" in value or "/" in value:
            continue
        prefix = text[max(0, match.start() - 48):match.start()]
        if re.search(r"(?:package|name|url|path)\s*:\s*$", prefix):
            continue
        names.add(value.lower())
    return names, excluded


def path_component_for(text, url, folder, excluded):
    identity = repository_basename(url).lower()
    by_names = []
    for match in re.finditer(r'"([^"]+)"', text):
        if excluded(match.start()):
            continue
        value = match.group(1)
        if value.lower() != identity:
            continue
        if "://" in value or "/" in value:
            continue
        prefix = text[max(0, match.start() - 48):match.start()]
        if re.search(r"(?:package|name|url|path)\s*:\s*$", prefix):
            continue
        by_names.append(value)
    for name in by_names:
        if name == folder:
            return name
    if by_names:
        return by_names[0]
    return folder


def validate_path_component(component):
    if (
        not component
        or component in {".", ".."}
        or "/" in component
        or "\\" in component
        or '"' in component
    ):
        stop(f"invalid local package path component: {component}")


def replace_package_calls(text, names, excluded):
    pieces = []
    cursor = 0
    for start, end in iter_balanced_calls(text, ".package("):
        call = text[start:end]
        pieces.append(text[cursor:start])
        replacement = call
        for url, folder in vendored_urls_in(call):
            identity = repository_basename(url).lower()
            if identity not in names and folder.lower() not in names:
                continue
            component = path_component_for(text, url, folder, excluded)
            validate_path_component(component)
            replacement = f'.package(path: "../{component}")'
            break
        pieces.append(replacement)
        cursor = end
    pieces.append(text[cursor:])
    return "".join(pieces)


def replace_dependency_functions(text, names, excluded):
    pattern = re.compile(
        r"func\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)\s*->\s*Package\.Dependency\s*\{"
    )
    pieces = []
    cursor = 0
    for match in pattern.finditer(text):
        open_index = match.end() - 1
        close_index = matching_brace(text, open_index)
        if close_index is None:
            continue
        body = text[open_index:close_index + 1]
        chosen = None
        for url, folder in vendored_urls_in(body):
            identity = repository_basename(url).lower()
            if identity in names or folder.lower() in names:
                chosen = (url, folder)
        pieces.append(text[cursor:match.start()])
        if chosen is None:
            pieces.append(text[match.start():close_index + 1])
        else:
            url, folder = chosen
            component = path_component_for(text, url, folder, excluded)
            validate_path_component(component)
            pieces.append(
                text[match.start():match.end()]
                + f'\n    return .package(path: "../{component}")\n'
                + "}"
            )
        cursor = close_index + 1
    pieces.append(text[cursor:])
    return "".join(pieces)


def manifest_paths(dest):
    found = []
    for name in sorted(os.listdir(dest)):
        if name == "Package.swift" or (name.startswith("Package@") and name.endswith(".swift")):
            path = os.path.join(dest, name)
            if os.path.isfile(path):
                found.append(path)
    return found


def rewrite_manifests(dest):
    changed = False
    for path in manifest_paths(dest):
        with open(path, encoding="utf-8", newline="") as handle:
            text = handle.read()
        names, excluded = non_test_package_names(text)
        updated = replace_package_calls(text, names, excluded)
        names, excluded = non_test_package_names(updated)
        updated = replace_dependency_functions(updated, names, excluded)
        identities = [
            os.path.basename(item).lower()
            for item in re.findall(r'\.package\(\s*path:\s*"\.\./([^"]+)"\)', updated)
        ]
        if len(identities) != len(set(identities)):
            stop(f"duplicate local package path in {path}")
        if updated != text:
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(updated)
            changed = True
    return changed


def rewrite_gitmodules(dest):
    path = os.path.join(dest, ".gitmodules")
    if not os.path.isfile(path):
        return False
    with open(path, encoding="utf-8", newline="") as handle:
        text = handle.read()
    lines = text.splitlines(keepends=True)
    changed = False
    rewritten = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("url =") or stripped.startswith("url="):
            url = stripped.split("=", 1)[1].strip()
            folder = None
            child = directory_for_url(url)
            if child and os.path.normpath(os.path.dirname(child)) == os.path.normpath(vendor):
                folder = os.path.basename(child)
            if folder:
                ending = "\n"
                if line.endswith("\r\n"):
                    ending = "\r\n"
                elif not line.endswith("\n"):
                    ending = ""
                replacement = f"\turl = {file_mirror(folder)}{ending}"
                if replacement != line:
                    changed = True
                    rewritten.append(replacement)
                    continue
        rewritten.append(line)
    if changed:
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write("".join(rewritten))
    return changed


def update_gitlinks(dest):
    for module in parse_gitmodules(dest):
        child = directory_for_url(module["url"])
        if not child or not has_commit(child):
            continue
        recorded = gitlink_sha(dest, module["path"])
        if not recorded:
            continue
        current = head_commit(child)
        if recorded == current or not is_ancestor(child, recorded, current):
            continue
        run(
            ["git", "update-index", "--add", "--cacheinfo", f"160000,{current},{module['path']}"],
            cwd=dest,
        )


def retarget_tags(dest, old_commit):
    if head_commit(dest) == old_commit:
        return
    for name in capture(["git", "tag", "--list"], cwd=dest).splitlines():
        if not name:
            continue
        try:
            pointed = tag_commit(dest, f"refs/tags/{name}")
        except subprocess.CalledProcessError:
            continue
        if pointed == old_commit:
            run(["git", "tag", "-f", name, "HEAD"], cwd=dest)


def commit_localization(dest):
    paths = [os.path.basename(path) for path in manifest_paths(dest)]
    gitmodules = os.path.join(dest, ".gitmodules")
    if os.path.isfile(gitmodules):
        paths.append(".gitmodules")
    if paths:
        run(["git", "add", "--", *paths], cwd=dest)
    # Stage gitlinks after git add so adding the manifest does not reset them.
    update_gitlinks(dest)
    result = subprocess.run(
        ["git", "diff", "--cached", "--quiet"],
        cwd=dest,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        return False
    old = head_commit(dest)
    run(
        ["git", "commit", "-m", LOCALIZATION_SUBJECT],
        cwd=dest,
    )
    retarget_tags(dest, old)
    ok(f"localized {os.path.basename(dest)} {head_commit(dest)[:12]}")
    return True


def localization_order():
    visiting = set()
    ordered = []

    def visit(dest):
        key = os.path.normpath(dest)
        if key in visiting:
            return
        visiting.add(key)
        if os.path.isdir(os.path.join(dest, ".git")):
            for module in parse_gitmodules(dest):
                child = directory_for_url(module["url"])
                if child:
                    visit(child)
        ordered.append(dest)

    for dest in vendor_git_directories():
        visit(dest)
    return ordered


def localize_checkouts():
    remembered = seed_submodule_sources()
    ensure_submodule_checkouts(remembered)
    committed = 0
    for dest in localization_order():
        rewrite_manifests(dest)
        rewrite_gitmodules(dest)
        if commit_localization(dest):
            committed += 1
    if committed == 0:
        ok("local dependency paths are current")
    records = []
    seen = set()
    for name, repository in sorted(remembered.items()):
        current = matching_child(vendor, name)
        if not current or current.lower() in seen:
            continue
        dest = os.path.join(vendor, current)
        if not has_commit(dest):
            continue
        seen.add(current.lower())
        records.append({
            "name": current,
            "repository": repository,
            "version": upstream_commit(dest),
            "via": "submodule",
        })
    return records


def refresh_checkout_names(records):
    for item in records:
        current = matching_child(vendor, item["name"])
        if not current:
            continue
        dest = os.path.join(vendor, current)
        if has_commit(dest):
            item["name"] = current


def sync():
    os.makedirs(vendor, exist_ok=True)
    migrate_transitive_folders()
    direct_records = []
    transitive_records = []
    folders_by_repository = {}

    total = len(direct_deps)
    for index, dep in enumerate(direct_deps, start=1):
        validate_name(dep["name"])
        repository = dep["repository"]
        key = normalize_repository(repository)
        if key in folders_by_repository:
            stop(f"duplicate repository in versions.json: {repository}")
        dest = os.path.join(vendor, dep["name"])
        label = f"[{index}/{total}] {dep['name']} {dep['version']}"
        commit = checkout_tag(repository, dest, dep["version"], label)
        folders_by_repository[key] = dep["name"]
        owned = [item for item in previous.get("transitive", []) if item.get("via") == dep["name"]]
        if closure_is_current(dep) and disk_matches(owned):
            ok(f"fetched {dep['name']} {dep['version']} {commit} (locked)")
            transitive_records.extend(owned)
        else:
            ok(f"fetched {dep['name']} {dep['version']} {commit}")
            transitive_records.extend(collect_transitive(dest, dep["name"], folders_by_repository))
        direct_records.append({
            "name": dep["name"],
            "repository": repository,
            "version": dep["version"],
            "resolved": True,
        })

    grouped = {}
    order = []
    for item in transitive_records:
        key = normalize_repository(item["repository"])
        if key not in grouped:
            order.append(key)
            grouped[key] = []
        grouped[key].append(item)

    selected = {}
    for key in order:
        chosen = choose_shared_package(grouped[key])
        chosen["name"] = folder_name_for_repository(chosen["repository"])
        if key in folders_by_repository:
            folder = folders_by_repository[key]
            if not checkout_matches(os.path.join(vendor, folder), chosen["version"]):
                pinned = next(dep["version"] for dep in direct_deps if dep["name"] == folder)
                stop(
                    f"{chosen['repository']} is pinned by versions.json at {pinned}, "
                    f"but {chosen['via']} resolved {chosen['version']}"
                )
            continue
        selected[key] = chosen

    for item in selected.values():
        dest = os.path.join(vendor, item["name"])
        label = f"{item['name']} {item['version']} via {item['via']}"
        checkout_version(item["repository"], dest, item["version"], label)
        retain_pinned_tag(dest, item["version"])

    locked_transitive = []
    for item in selected.values():
        locked_transitive.append({
            "name": item["name"],
            "repository": item["repository"],
            "version": item["version"],
            "via": item["via"],
        })
    publish_records = list(selected.values())
    submodule_records = localize_checkouts()
    refresh_checkout_names(direct_records)
    refresh_checkout_names(locked_transitive)
    refresh_checkout_names(publish_records)
    known_names = {item["name"].lower() for item in direct_records + locked_transitive}
    for record in submodule_records:
        if record["name"].lower() in known_names:
            continue
        locked_transitive.append(record)
        publish_records.append(record)
        known_names.add(record["name"].lower())

    with open(lock_path, "w", encoding="utf-8") as handle:
        json.dump(
            {"dependencies": direct_records, "transitive": locked_transitive},
            handle,
            indent=2,
        )
        handle.write("\n")
    ok(f"wrote {lock_path}")
    publish_mirrors(direct_records, publish_records)
    purge_stale_package_caches(direct_records, publish_records)


def local_checkout_state(dest):
    if not os.path.isdir(os.path.join(dest, ".git")) or not has_commit(dest):
        return None
    listed = capture(["git", "tag", "--list"], cwd=dest).splitlines()
    tags = {name for name in listed if name}
    return head_commit(dest), tags


def git_dir_capture(git_dir, args):
    result = subprocess.run(
        ["git", "--git-dir", git_dir, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def path_from_git_url(url):
    if not url:
        return None
    text = url.strip()
    if text.startswith("file:"):
        parsed = urllib.parse.urlparse(text)
        raw = urllib.parse.unquote(parsed.path)
    elif text.startswith("/") or text.startswith("~"):
        raw = os.path.expanduser(text)
    else:
        return None
    if not raw:
        return None
    return os.path.realpath(raw)


def repository_cache_roots():
    roots = []
    derived = pathlib.Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived.is_dir():
        for child in derived.iterdir():
            repos = child / "SourcePackages" / "repositories"
            if repos.is_dir():
                roots.append(repos)
    swiftpm = pathlib.Path.home() / "Library/Caches/org.swift.swiftpm/repositories"
    if swiftpm.is_dir():
        roots.append(swiftpm)
    return roots


def purge_stale_package_caches(direct_records, transitive_records):
    expected = {}
    for item in list(direct_records) + list(transitive_records):
        dest = os.path.realpath(os.path.join(vendor, item["name"]))
        state = local_checkout_state(dest)
        if state is None:
            continue
        expected[dest] = (state, item["name"])
    removed = []
    for root in repository_cache_roots():
        for entry in sorted(os.listdir(root)):
            git_dir = os.path.join(root, entry)
            if not os.path.isdir(git_dir):
                continue
            origin = git_dir_capture(git_dir, ["config", "--get", "remote.origin.url"])
            local = path_from_git_url(origin)
            matched = expected.get(local)
            if matched is None and local:
                for candidate, record in expected.items():
                    try:
                        if os.path.samefile(local, candidate):
                            matched = record
                            break
                    except OSError:
                        continue
            if matched is None:
                continue
            (head, tags), folder_name = matched
            cached_head = git_dir_capture(git_dir, ["rev-parse", "HEAD"])
            cached_tags = git_dir_capture(git_dir, ["tag", "--list"])
            cached_tag_set = set()
            if cached_tags:
                cached_tag_set = {name for name in cached_tags.splitlines() if name}
            origin_name = repository_basename(origin or "")
            if cached_head == head and tags <= cached_tag_set and origin_name == folder_name:
                continue
            try:
                remove_tree(git_dir)
            except OSError as exc:
                stop(f"could not remove stale package cache {git_dir}: {exc}")
            removed.append(git_dir)
            ok(f"removed stale package cache {git_dir}")
    if not removed:
        ok("package caches match local checkouts")


def file_mirror(folder_name):
    directory = os.path.abspath(os.path.join(vendor, folder_name))
    if not os.path.isdir(directory):
        stop(f"{folder_name}: local mirror directory does not exist: {directory}")
    return pathlib.Path(directory).as_uri()


def project_mirror_paths(root):
    paths = []
    for name in sorted(os.listdir(root)):
        project = os.path.join(root, name)
        if not os.path.isdir(project):
            continue
        if name.endswith(".xcodeproj"):
            paths.append(os.path.join(
                project,
                "project.xcworkspace",
                "xcshareddata",
                "swiftpm",
                "configuration",
                "mirrors.json",
            ))
        elif name.endswith(".xcworkspace"):
            paths.append(os.path.join(
                project,
                "xcshareddata",
                "swiftpm",
                "configuration",
                "mirrors.json",
            ))
    return paths


def publish_mirrors(direct_records, transitive_records):
    entries = []
    seen = set()
    for item in list(direct_records) + list(transitive_records):
        repositories = item.get("urls") or [item["repository"]]
        mirror = file_mirror(item["name"])
        for repository in repositories:
            for form in repository_url_forms(repository):
                if form in seen:
                    continue
                seen.add(form)
                entries.append({
                    "original": form,
                    "mirror": mirror,
                })
    entries.sort(key=lambda item: item["original"])
    payload = json.dumps({"object": entries, "version": 1}, indent=2) + "\n"
    os.makedirs(os.path.dirname(generated_mirrors_path), exist_ok=True)
    with open(generated_mirrors_path, "w", encoding="utf-8") as handle:
        handle.write(payload)
    ok(f"wrote {generated_mirrors_path}")

    destinations = project_mirror_paths(repo_root)
    if not destinations:
        stop(f"no Xcode project under {repo_root} to receive mirrors.json")
    for destination in destinations:
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(generated_mirrors_path, destination)
        ok(f"copied mirrors.json to {destination}")
try:
    sync()
except CommandError as exc:
    fail(str(exc) or "command failed")
    raise SystemExit(1)
except SystemExit:
    raise
except Exception as exc:
    fail(str(exc))
    raise SystemExit(1)

PY
