# spm-install

English: [README.en.md](README.en.md)

把 Swift Package 依赖按精确版本检到工程本地的 `ThirdParty/`，让 Xcode 之后的解析和编译走本地目录。业务仓库只提交 `versions.json` 和 `lock.json`。本仓库只提供安装脚本和同步脚本，不携带任何业务依赖清单。

## Swift Package Manager 现在的问题

Xcode 集成的 Swift Package Manager 适合依赖少、网络稳定、版本范围宽松的小工程。依赖一多、要在团队和 CI 里反复构建时，下面几件事会反复出现。

### 解析绑在远程仓库上

添加远程包之后，Xcode 在打开工程、清理 DerivedData、升级 Xcode、或 `Package.resolved` 对不上时，都会重新走一遍 Resolving Package Versions。这一步要访问每个包的 Git 地址，还要再访问这些包自己 `Package.swift` 里声明的下一级地址。

把某个包改成 Add Local Package 也挡不住后续请求。本地包的清单里，依赖项大多仍是 `https://github.com/...`。Kingfisher 指向自己的传递依赖，Firebase 指向一组子仓库，任意一个地址超时、证书失败、或 GitHub 限流，整次解析就停住。国内办公网、代理和 CI 机器上，这类失败很常见，报错又经常只剩 `Could not resolve host` 或一条 clone 超时。

`mirrors.json` 可以把原始远程地址映射到本地目录，这是 SwiftPM 自己的镜像机制。要手写这份文件，得覆盖直接依赖、传递依赖，以及带 `.git` 和不带 `.git` 的两种 URL。依赖一升级，镜像表就过期。

### 同一次声明，不同时间解出不同版本

业务工程里常见的写法是范围依赖，例如 `from: "8.0.0"`。SwiftPM 在解析当时，从远程标签里选一个落在范围内的版本。今天和三个月后的选择可以不同，两个同事隔周拉取也可能不同。

`Package.resolved` 能记下一次解析结果，但它由 Xcode 读写。清理缓存、改一处版本、换一台机器，都可能触发重新解析，锁文件跟着被改写。传递依赖藏在各个包的 `Package.swift` 里，业务仓库里看不到完整闭包，出了版本冲突时，报错也很少直接写明「是哪个包要求了哪段范围」。

### 缓存和本地检出对不上

Xcode 把拉下来的仓库放在 `DerivedData/<工程>/SourcePackages/repositories`，SwiftPM 自己还有一份 `~/Library/Caches/org.swift.swiftpm/repositories`。升级一个包、改一次镜像路径、或清单被改写后标签指向了新提交时，这两处缓存仍可能留着旧的 HEAD 和旧 tag。下次编译继续命中旧缓存，表现是「本地目录已经是新版本，Xcode 还在用旧代码」，或者镜像路径的大小写和真实目录不一致，SwiftPM 按标识找不到包。

### 没有一套适合业务仓库的固定流程

CocoaPods 把「直接依赖写在 Podfile、完整闭包写在 Podfile.lock」分成两份文件，团队提交锁文件，再在本机物化源码。SwiftPM 没有对应的官方流程：

- 把全部依赖源码提交进业务仓库，diff 和仓库体积会立刻变大，升级一次就是几千个文件。
- 不提交源码，每个人和每台 CI 都要重新向远程解析。
- 部分上游用 git submodule 带进源码。SwiftPM 按包解析，不会把这些 submodule 收成可重复检出的本地目录。

私有 GitLab 和公共 GitHub 混用时，SSH 与 HTTPS、本机凭证和 CI 凭证也不在同一套解析路径里，某台机器能打开工程，另一台卡在鉴权。

大仓库的完整 clone 同样慢。业务通常只需要一个 tag，Xcode 仍可能拉下整段历史。

## 这个方案怎么处理

`spm-install` 在业务工程根目录读取两份 JSON，把依赖检到 `ThirdParty/<name>/`，再让 Xcode 只认这些本地目录。

| 问题 | 处理方式 |
|------|----------|
| 解析要访问远程，传递依赖也是远程地址 | 按 `versions.json` 把直接依赖浅克隆到 `ThirdParty/`。读取每个包非测试 target 真正用到的依赖，继续检到同级目录。然后把这些包的 `Package.swift`（含 `Package@swift-*.swift`）里、指向已检目录的 `.package(url:)` 改写成 `.package(path: "../<目录名>")`。返回 `Package.Dependency` 的辅助函数同样改写。 |
| 手写 `mirrors.json` 容易漏、容易过期 | 为每个本地目录生成镜像项，同一仓库的 `.git` 与不带 `.git` 两种 URL 都写入。文件写到工程根的 `.swiftpm/configuration/mirrors.json`，并复制到根目录下每个 `.xcodeproj` 和 `.xcworkspace` 的 SwiftPM 配置目录。Xcode 遇到原始远程地址时改读本地目录。 |
| 同一范围在不同时间选出不同版本 | 直接依赖在 `versions.json` 里写成明确 tag（或 40 位提交）。传递依赖若已在 `lock.json` 中、且仍满足上游清单的范围，继续使用锁定版本；否则在远程 tag 中选择范围内的最高版本。精确版本、提交、分支按清单原样使用。多个上游要求同一仓库时，取同时满足全部范围的版本；无法同时满足则停止，并打印每个上游要求的范围。 |
| 业务仓库看不到完整闭包 | 生成根目录 `lock.json`，分别记录直接依赖和传递依赖的目录名、仓库地址、版本，传递项还带 `via`（由哪个直接依赖带入，或 `submodule`）。业务仓库提交 `versions.json` 和 `lock.json`。 |
| DerivedData 与 SwiftPM 缓存仍指向旧提交 | 比对缓存仓库的 HEAD、tag、目录名和本地检出。不一致的缓存目录删掉，下次由本地检出重新建立。 |
| 源码提交进业务仓库体积过大 | `ThirdParty/` 不入库。新同事安装一次命令、克隆业务仓库、执行 `spm-install`，即可按锁文件得到同一套目录。版本已与锁和磁盘一致时，跳过重新下载。 |
| 上游包内的 git submodule | 读取 `.gitmodules` 和 gitlink 上的提交，把子模块检到 `ThirdParty/`，把 `.gitmodules` 的 URL 改成指向该目录的 `file://` 地址，并在本地提交上保留对应对象。 |
| 只需要一个 tag，却拉下整段历史 | 标签依赖使用 `git clone --depth 1 --branch <tag>`。提交依赖使用 `git fetch --depth 1`。 |
| 镜像路径被 Xcode 改成小写后对不上目录名 | 本地目录名与清单里 by-name 依赖的大小写对齐；仅大小写不同的已有目录会先改名再使用。 |

改写只发生在 `ThirdParty/` 里的本地检出，并记一笔提交说明为 `Use local dependency paths and submodule checkouts`。这笔提交留在本机，用来让 tag 仍指向「已改成本地路径」的清单，业务仓库不包含这些提交。传递依赖上多余的 tag 会去掉，只保留当前钉住的那一个，并移除 `origin`，避免之后的解析又走回远程。

第一次同步需要能访问 `versions.json` 里的上游地址。同步完成后，编译使用 `ThirdParty/` 和 `mirrors.json`。依赖种类由各业务工程自己的 `versions.json` 决定，工具不内置固定清单。

根目录需要至少有一个 `.xcodeproj` 或 `.xcworkspace`，否则无法写入镜像配置，命令会停在这一步。测试 target 上的依赖不进入闭包。

## 环境要求

- macOS
- `git`
- `python3`
- `swift`（Xcode 命令行工具或完整 Xcode）

## 安装（每台机器一次）

```bash
git clone git@gitlab1.surfin-cn.com:iOS_Apps/spmscript.git /tmp/spmscript
bash /tmp/spmscript/install.sh
rm -rf /tmp/spmscript
```

`install.sh` 把命令安装为 `spm-install`。`/usr/local/bin` 可写时用这个目录，否则用 `~/.local/bin`，并在需要时自动创建。不必事先自己建 `~/.local/bin`。

安装前会检查 `git`、`python3`、`swift` 是否在 `PATH` 中。

### PATH

安装脚本若提示目标目录不在 `PATH` 里，把打印出的那一行写入 `~/.zshrc`，再重新加载：

```bash
export PATH="$HOME/.local/bin:$PATH"
source ~/.zshrc
```

自定义安装位置：

```bash
PREFIX="$HOME/bin" bash /tmp/spmscript/install.sh
```

### 确认安装

```bash
which spm-install
echo $PATH
spm-install --help
```

预期结果：

- `which spm-install` 打印 `/usr/local/bin/spm-install` 或 `$HOME/.local/bin/spm-install`
- `echo $PATH` 包含该目录
- `spm-install --help` 打印用法

`which` 找不到命令时，把安装目录加入 `~/.zshrc`，执行 `source ~/.zshrc` 后再查一次。

## 业务工程需要的文件

### 1. `versions.json`（直接依赖）

放在业务工程根目录。每个工程维护自己的清单：

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

| 字段 | 含义 |
|------|------|
| `name` | `ThirdParty/<name>` 的目录名 |
| `repository` | 上游 Git 地址 |
| `version` | 上游 tag，例如 `8.9.0`。需要钉提交时填写 40 位 SHA |

同一仓库地址不要写两行。`version` 是 tag 时，脚本会依次尝试原样和补上 `v` 前缀的 tag，并确认检出的提交就是该 tag，而不是同名分支。

### 2. `lock.json`（完整闭包）

由 `spm-install` 写在 `versions.json` 旁边，记录直接依赖和传递依赖，提交进业务仓库。

直接项包含 `name`、`repository`、`version`、`resolved`。传递项再加 `via`：普通传递依赖的值是引入它的直接依赖名，子模块检出的值是 `submodule`。

旧版本若把锁文件放在 `ThirdParty/lock.json`，第一次运行会把它移到工程根目录。

### 3. `.gitignore`

业务工程建议忽略：

```gitignore
ThirdParty/*
.swiftpm/
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json
*.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json
```

根目录的 `lock.json` 要提交，不要忽略。

### 4. 接入 Xcode

先执行一次 `spm-install`，再对需要链接到 App 的包使用 Add Local Package，例如：

- `ThirdParty/Kingfisher`
- `ThirdParty/Firebase`

路径相对工程填写。传递依赖由镜像和改写后的本地路径接上，不必逐个加进工程。

## 日常使用

```bash
cd <业务工程根目录>
spm-install
```

也可以在子目录里执行。命令会向上查找，直到找到 `versions.json`。

一次运行会：

1. 按 `versions.json` 和已有 `lock.json` 把依赖检到 `ThirdParty/`
2. 把包与包之间的远程地址改写为同级本地路径，并处理子模块
3. 生成或更新 `mirrors.json`，复制到根目录下的 Xcode 工程和 workspace
4. 在工程根目录写入 `lock.json`
5. 清掉与当前检出不一致的 Xcode / SwiftPM 仓库缓存

然后打开 Xcode 工程编译。

终端里下载过程以黄色进度显示；完成项为绿色。设置环境变量 `NO_COLOR` 可关闭颜色。

## 新增或升级依赖

1. 修改 `versions.json`（新增一条，或改 `version`）
2. 在工程根目录执行 `spm-install`
3. 若 App 需要新产品，在 Xcode 里添加对应的 Local Package
4. 提交 `versions.json` 和更新后的 `lock.json`

只改传递依赖的锁定结果时，不需要改 `versions.json`，重新执行 `spm-install` 后提交新的 `lock.json` 即可。已锁定且仍满足上游范围的版本会保持不变。

## 新同事

```bash
# 1. 按上面的步骤在本机安装 spm-install
# 2. 克隆业务工程
git clone <业务工程地址>
cd <业务工程>

# 3. 按锁文件检出本地依赖
spm-install

# 4. 打开 Xcode 工程并编译
```

## 提交范围

| 路径 | 是否提交 |
|------|----------|
| `versions.json` | 提交 |
| `lock.json` | 提交 |
| 业务源码和 Xcode 工程 | 提交 |
| `ThirdParty/*` | 不提交 |
| `.swiftpm/`、`mirrors.json` | 不提交 |
| 本仓库的 `spm-install.sh`、`install.sh` | 只存在于本工具仓库，业务工程不需要拷贝 |

## 失败时怎么看

**`spm-install: no versions.json in ...`**  
当前目录及其上级都没有 `versions.json`。先进入业务工程再执行。

**clone 失败，输出里有 `Could not resolve host` 或其他 git 错误**  
脚本会打印 git 的原始错误。确认能访问对应上游地址后重新执行。中断的一次运行可以再次执行，已与目标 tag 一致的目录会跳过下载。

**找不到 `lock.json`**  
它写在 `versions.json` 旁边。若旧工程仍把锁文件放在 `ThirdParty/lock.json`，第一次运行会移到工程根目录。

**`no Xcode project under ... to receive mirrors.json`**  
`versions.json` 所在目录下没有 `.xcodeproj` 或 `.xcworkspace`。镜像配置要写进工程目录，把命令用在该工程的根目录。

**某个依赖 `missing Package.swift`，或 `swift package dump-package` 失败**  
该检出不是 Swift 包，或清单无法被当前 `swift` 读取。看命令打印的目录和 swift 原文。

**`version conflict for ...`**  
多个上游对同一仓库的范围无法同时满足，或 `versions.json` 钉住的版本和传递依赖解析出的版本不一致。输出里会带上每个 `via` 和要求的范围。调整直接依赖版本，或更换上游组合后再执行。

**`could not check out <version>`**  
远程没有这个 tag，也没有 `v` 前缀的同名 tag，或同名引用不是 tag。`version` 要写成上游真实存在的 tag；钉提交时用完整 40 位 SHA。

**不同工程的依赖完全不同**  
每个业务工程使用自己的 `versions.json` 和 `lock.json`。

## 本仓库内容

```
install.sh      # 把 spm-install 安装到本机
spm-install.sh  # 依赖同步实现
README.md       # 中文说明
README.en.md    # 英文说明
```
