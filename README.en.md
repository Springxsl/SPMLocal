# spm-install

中文：[README.md](README.md)

Pin Swift Package dependencies at exact versions in a local `ThirdParty/` checkout, so later Xcode resolution and builds read those directories. Business repositories commit only `versions.json` and `lock.json`. This repository ships the installer and the sync script. It does not carry a project-specific dependency list.

## Current problems with Swift Package Manager

Swift Package Manager inside Xcode works for a small project with few dependencies, a stable network, and loose version ranges. The following shows up once a team or CI rebuilds a larger graph.

### Resolution stays tied to remote repositories

After a remote package is added, Xcode runs Resolving Package Versions again when the project is opened, DerivedData is cleared, Xcode is upgraded, or `Package.resolved` no longer matches. That step contacts every package URL, then the next URLs declared in each package's own `Package.swift`.

Switching one package to Add Local Package does not stop the later requests. Dependencies inside a local package manifest are still mostly `https://github.com/...`. Kingfisher points at its own transitive packages. Firebase points at a set of child repositories. One timeout, certificate failure, or GitHub rate limit stops the whole resolve. This is common on office networks, proxies, and CI machines. The visible error is often only `Could not resolve host` or a clone timeout.

`mirrors.json` can map an original remote URL to a local directory. That is SwiftPM's own mirror mechanism. Writing the file by hand means listing direct dependencies, transitive dependencies, and both the `.git` and non-`.git` forms of each URL. The table goes stale on the next upgrade.

### The same declaration resolves to different versions over time

Business projects often use a range, for example `from: "8.0.0"`. At resolve time SwiftPM picks a remote tag inside that range. The pick today and the pick three months later can differ. Two teammates who update a week apart can also differ.

`Package.resolved` records one resolve, and Xcode owns that file. Clearing caches, changing one version, or moving to another machine can resolve again and rewrite the lock. Transitive dependencies live in each package's `Package.swift`. The business repository does not show the full closure. A version conflict rarely names which package asked for which range.

### Caches and the local checkout diverge

Xcode stores fetched repositories under `DerivedData/<project>/SourcePackages/repositories`. SwiftPM keeps another copy in `~/Library/Caches/org.swift.swiftpm/repositories`. After a package upgrade, a mirror-path change, or a rewritten manifest whose tag now points at a new commit, both caches can still hold the old HEAD and the old tag. The next build hits that cache: the local directory is already the new version, while Xcode compiles the old code. A mirror path whose letter case does not match the real directory makes SwiftPM miss the package identity.

### There is no workflow that fits a business repository

CocoaPods splits "direct dependencies in the Podfile" from "the full closure in Podfile.lock". The team commits the lock, then materializes source on each machine. SwiftPM has no matching official flow:

- Committing every dependency's source into the business repository inflates diffs and history. One upgrade touches thousands of files.
- Leaving the source out means every person and every CI job resolves against the network again.
- Some upstreams bring source in through git submodules. SwiftPM resolves packages. It does not turn those submodules into checkouts that can be repeated from a lock file.

Private GitLab and public GitHub also mix SSH with HTTPS, and laptop credentials with CI credentials. One machine opens the project. Another stops on authentication.

A full clone of a large repository is slow for the same reason. The product usually needs one tag. Xcode can still download the whole history.

## How this tool handles that

`spm-install` reads two JSON files at the business project root, checks the dependencies out under `ThirdParty/<name>/`, and makes Xcode use those local directories.

| Problem | What the tool does |
|---------|--------------------|
| Resolution contacts remotes, and transitive dependencies are remote URLs too | Shallow-clones direct dependencies from `versions.json` into `ThirdParty/`. Reads the dependencies actually used by each package's non-test targets and checks those out as siblings. Rewrites `.package(url:)` entries that point at a vendored directory into `.package(path: "../<folder>")` inside `Package.swift` and `Package@swift-*.swift`. Helper functions that return `Package.Dependency` are rewritten the same way. |
| A hand-written `mirrors.json` is easy to miss and easy to leave stale | Writes a mirror entry for every local directory, including both the `.git` and non-`.git` URL of the same repository. The file is written to `.swiftpm/configuration/mirrors.json` at the project root and copied into the SwiftPM configuration of every `.xcodeproj` and `.xcworkspace` in that root. When Xcode sees the original remote URL, it reads the local directory. |
| The same range selects different versions at different times | Direct dependencies are an exact tag (or a 40-character commit) in `versions.json`. A transitive dependency that is already in `lock.json` and still satisfies the upstream manifest keeps that locked version. Otherwise the highest remote tag inside the range is chosen. Exact versions, revisions, and branches are used as declared. When several parents require the same repository, one version that satisfies every range is chosen. If none can, the command stops and prints each parent's range. |
| The business repository cannot see the full closure | Writes `lock.json` at the project root with folder name, repository, and version for direct and transitive dependencies. Transitive entries also include `via` (the direct dependency that pulled them in, or `submodule`). The business repository commits `versions.json` and `lock.json`. |
| DerivedData and the SwiftPM cache still point at an old commit | Compares HEAD, tags, and folder name in each cached repository with the local checkout. Cache directories that differ are removed. The next build rebuilds them from the local checkout. |
| Committing dependency source makes the business repository too large | `ThirdParty/` stays untracked. A new teammate installs the command, clones the business repository, and runs `spm-install` to get the same directories from the lock. A directory whose version already matches the lock and the disk skips the download. |
| Git submodules inside an upstream package | Reads `.gitmodules` and the gitlink commit, checks the submodule out into `ThirdParty/`, rewrites the `.gitmodules` URL to a `file://` URL for that directory, and keeps the object on the local commit. |
| Only one tag is needed, but the whole history is downloaded | Tag dependencies use `git clone --depth 1 --branch <tag>`. Commit dependencies use `git fetch --depth 1`. |
| Xcode lowercases a mirror path and it no longer matches the folder | Local folder names follow the by-name dependency spelling in the manifest. An existing folder that differs only by case is renamed before use. |

Rewrites happen only inside the local checkouts under `ThirdParty/`. Each rewrite is recorded with the commit message `Use local dependency paths and submodule checkouts`. That commit stays on the machine so the tag still points at the manifest that uses local paths. The business repository does not contain these commits. Extra tags on a transitive checkout are removed, leaving the one pin, and `origin` is removed so a later resolve does not go back to the remote.

The first sync needs access to the upstream URLs in `versions.json`. After that, builds use `ThirdParty/` and `mirrors.json`. Each business project decides its own dependencies in `versions.json`. The tool does not ship a fixed list.

The project root needs at least one `.xcodeproj` or `.xcworkspace`. Without that, the mirror configuration cannot be installed and the command stops. Dependencies that appear only on test targets stay out of the closure.

## Requirements

- macOS
- `git`
- `python3`
- `swift` (Xcode Command Line Tools or a full Xcode install)

## Install (once per machine)

```bash
git clone git@gitlab1.surfin-cn.com:iOS_Apps/spmscript.git /tmp/spmscript
bash /tmp/spmscript/install.sh
rm -rf /tmp/spmscript
```

`install.sh` installs the command as `spm-install`. It uses `/usr/local/bin` when that directory is writable. Otherwise it uses `~/.local/bin` and creates that directory when needed. You do not need to create `~/.local/bin` by hand.

The installer checks that `git`, `python3`, and `swift` are on `PATH` before it copies the command.

### PATH

If the installer reports that the target directory is not on `PATH`, add the printed line to `~/.zshrc`, then reload the shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
source ~/.zshrc
```

Custom install location:

```bash
PREFIX="$HOME/bin" bash /tmp/spmscript/install.sh
```

### Verify the install

```bash
which spm-install
echo $PATH
spm-install --help
```

Expected result:

- `which spm-install` prints `/usr/local/bin/spm-install` or `$HOME/.local/bin/spm-install`
- `echo $PATH` includes that directory
- `spm-install --help` prints the usage text

If `which spm-install` finds nothing, add the install directory to `~/.zshrc`, run `source ~/.zshrc`, and check again.

## Files each business project needs

### 1. `versions.json` (direct dependencies)

Keep this at the business project root. Each project maintains its own list:

```json
{
  "dependencies": [
    {
      "name": "Kingfisher",
      "repository": "https://github.com/onevcat/Kingfisher.git",
      "version": "8.9.0"
    },
    {
      "name": "SnapKit",
      "repository": "https://github.com/SnapKit/SnapKit.git",
      "version": "5.7.1"
    }
  ]
}
```

| Field | Meaning |
|-------|---------|
| `name` | Folder name under `ThirdParty/<name>` |
| `repository` | Upstream Git URL |
| `version` | Upstream tag, for example `8.9.0`. Use a 40-character SHA to pin a commit |

Do not list the same repository URL twice. For a tag, the script tries the version as written and again with a `v` prefix, then checks that the checkout is that tag and not a branch of the same name.

### 2. `lock.json` (full closure)

`spm-install` writes this next to `versions.json`. It records direct and transitive dependencies and is committed to the business repository.

Direct entries contain `name`, `repository`, `version`, and `resolved`. Transitive entries also contain `via`: the direct dependency that pulled the package in, or `submodule` for a submodule checkout.

If an older project still has `ThirdParty/lock.json`, the first run moves it to the project root.

### 3. `.gitignore`

Recommended ignores for the business project:

```gitignore
ThirdParty/*
.swiftpm/
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json
*.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json
```

Commit the root `lock.json`. Leave it out of `.gitignore`.

### 4. Xcode integration

Run `spm-install` once, then use Add Local Package for the packages the app links, for example:

- `ThirdParty/Kingfisher`
- `ThirdParty/Firebase`

Use paths relative to the project. Transitive dependencies are connected through mirrors and the rewritten local paths. They do not each need to be added to the project.

## Daily usage

```bash
cd <business-project-root>
spm-install
```

The command can also be started from a subdirectory. It walks upward until it finds `versions.json`.

One run will:

1. Check dependencies out into `ThirdParty/` from `versions.json` and the existing `lock.json`
2. Rewrite package-to-package remote URLs to sibling local paths, and materialize submodules
3. Write or refresh `mirrors.json`, and copy it into the Xcode project and workspace at the root
4. Write `lock.json` at the project root
5. Remove Xcode / SwiftPM repository caches that do not match the current checkouts

Then open the Xcode project and build.

Download progress is yellow. Finished lines are green. Set `NO_COLOR` to turn colors off.

## Add or upgrade a dependency

1. Edit `versions.json` (add an entry, or change `version`)
2. Run `spm-install` at the project root
3. If the app needs a new product, add that Local Package in Xcode
4. Commit `versions.json` and the updated `lock.json`

When only a transitive lock result changes, leave `versions.json` as it is, run `spm-install` again, and commit the new `lock.json`. A locked version that still satisfies the upstream range stays in place.

## Onboarding a new teammate

```bash
# 1. Install spm-install on the machine (see above)
# 2. Clone the business project
git clone <business-project-url>
cd <business-project>

# 3. Check out local dependencies from the lock
spm-install

# 4. Open the Xcode project and build
```

## What to commit

| Path | Commit? |
|------|---------|
| `versions.json` | Yes |
| `lock.json` | Yes |
| App source and the Xcode project | Yes |
| `ThirdParty/*` | No |
| `.swiftpm/`, `mirrors.json` | No |
| `spm-install.sh` / `install.sh` from this repo | Only in this tool repo; business projects do not need a copy |

## Troubleshooting

**`spm-install: no versions.json in ...`**  
Neither the current directory nor any parent contains `versions.json`. Enter the business project first.

**Clone failed with `Could not resolve host` or another git error**  
The script prints the original git error. Confirm the upstream URL is reachable, then run `spm-install` again. An interrupted run can be repeated. A directory that already matches the target tag skips the download.

**Where is `lock.json`?**  
Next to `versions.json`. If an older project still has `ThirdParty/lock.json`, the first run moves it to the project root.

**`no Xcode project under ... to receive mirrors.json`**  
The directory that contains `versions.json` has no `.xcodeproj` or `.xcworkspace`. Mirror configuration is written into the project. Run the command at that project's root.

**A dependency reports `missing Package.swift`, or `swift package dump-package` fails**  
That checkout is not a Swift package, or the current `swift` cannot read its manifest. The command prints the directory and the swift output.

**`version conflict for ...`**  
Several parents require ranges that cannot be satisfied together, or the version pinned in `versions.json` does not match the version resolved for a transitive dependency. The output names each `via` and the range it requires. Change the direct version, or change the upstream set, then run again.

**`could not check out <version>`**  
The remote has neither that tag nor the same tag with a `v` prefix, or the matching ref is not a tag. Write `version` as a tag that exists upstream. To pin a commit, use the full 40-character SHA.

**Different projects need different packages**  
Each business project keeps its own `versions.json` and `lock.json`.

## Repository contents

```
install.sh      # installs spm-install on the machine
spm-install.sh  # dependency sync implementation
README.md       # Chinese documentation
README.en.md    # English documentation
```
