# Gitleaks 本地 Git Hook 操作手册

本目录提供 Gitleaks 本地安装与修复脚本，以及两个 Git Hook 模板。它不会修改 GitHub 组织设置，也不能强制所有开发者启用本地 Hook。服务端仍应启用 GitHub Secret Scanning Push Protection。

## 适用范围与前提

- 支持 macOS 和 Linux 的 arm64/aarch64、x86_64/amd64 架构。
- 需要 Git、`tar`、SHA-256 校验工具（`shasum` 或 `sha256sum`）；未安装 Gitleaks 时，还需要 `curl` 或 `wget`。
- 安装脚本使用官方 Gitleaks v8.30.1 发布包和固定的 SHA-256 校验值，安装到 `$HOME/.local/bin`，不需要 `sudo` 或 Homebrew。
- 目标必须是非 bare 的 Git 仓库。默认操作当前工作目录所在仓库，而不是脚本所在仓库。

在目标仓库中执行：

```sh
/path/to/actions/gitleaks-hooks/setup.sh
```

也可以显式指定目标仓库：

```sh
/path/to/actions/gitleaks-hooks/setup.sh --repo /path/to/repo
/path/to/actions/gitleaks-hooks/setup.sh --check --repo /path/to/repo
```

`setup.sh` 也可以单独通过 `curl` 获取并执行，不需要同时下载 `templates/`。将 `<commit-sha>` 替换为已审核、已发布且包含本目录的固定提交：

```sh
curl -fsSL 'https://raw.githubusercontent.com/pingkaicloud/actions/<commit-sha>/gitleaks-hooks/setup.sh' | \
  sh -s -- --repo /path/to/repo
```

需要只读检查时，在 `sh -s --` 后增加 `--check`。不要从未审核的 URL 执行脚本；直接管道执行时，某些 shell 不会把 `curl` 的失败作为整条管道的失败返回。更稳妥的做法是先下载到临时文件、核对内容，再用 `sh` 执行。若仓库是私有仓库，还需要有权获取脚本；不要把访问令牌写入命令、脚本或文档。当前文件尚未提交或发布，在提交可访问前，上述远端 URL 不会生效。

默认命令检查并修复本地 Gitleaks、`.githooks/pre-commit`、`.githooks/pre-push` 以及仓库本地的 `core.hooksPath`。`--check` 只检查；缺失或不匹配时返回非零状态。修复后可再次运行 `--check` 验证。脚本不会暂存、提交或推送文件。

如果在国内无法访问 GitHub，可设置常规的 `HTTPS_PROXY`/`HTTP_PROXY`，或为相同的发布包指定可信镜像：

```sh
GITLEAKS_DOWNLOAD_BASE=https://trusted-mirror.example/gitleaks/v8.30.1 \
  /path/to/actions/gitleaks-hooks/setup.sh --repo /path/to/repo
```

即使使用镜像，脚本仍会校验固定的 SHA-256 值。不要使用不可信镜像，也不要为了让下载通过而修改校验值。

## Hook 扫描范围

- `pre-commit` 使用 `gitleaks git --staged` 扫描暂存区中的新增内容，不扫描未暂存文件或更早的提交。
- `pre-push` 读取 Git 提供的每条 ref 更新，扫描 `old..new` 范围；推送 annotated tag 时，还会扫描标签对象及其嵌套标签的注释。首次推送远端分支或标签时，扫描新 ref 可达的历史，但排除目标远端的本地跟踪引用（`refs/remotes/<remote>/*`）已包含的提交。如果本地缺少已有远端 ref 的旧提交，Hook 会拒绝推送；先运行 `git fetch`，再重试。删除 ref 不会产生需要扫描的新提交。
- 两个 Hook 都会隐藏检测结果中的敏感值。若目标仓库存在 `.gitleaks.toml`，Gitleaks 会自动读取；使用默认规则不需要额外配置。

新 ref 的排除范围来自本地缓存，Hook 不会自动执行 `git fetch`。本地没有目标远端的跟踪引用时仍会扫描全部可达历史；缓存过期时可能多扫或漏扫，更新远端引用后再推送可提高范围的准确性。新分支的所有新增提交都会被检查，包括在后续提交中删除的内容。真实泄露的凭据应核实并轮换。只有确认误报后才添加范围尽量小、经过审核的例外；不要为了通过 Hook 而整体忽略目录或某类密钥。

## 安全边界与冲突处理

安装脚本会修复缺失的 Hook、执行权限及仓库本地的 `core.hooksPath`。它不会自动覆盖内容不同的 Hook，即使文件保留了受控标记；升级旧模板时需要先手动核对并合并。脚本也拒绝符号链接或不同的 `core.hooksPath`，并在切换 Hook 目录前检查 `.git/hooks` 中可能生效的其他 Hook，避免将其静默停用。安装前可运行 `git config --show-origin --get core.hooksPath` 核对当前配置。

安装后检查 `.githooks/`。如果希望 Hook 随仓库分发，应将两个 Hook 文件连同可执行权限一起提交。新克隆的仓库会取得文件，但**不会自动启用 Hook**；每位开发者都需要运行安装脚本，或执行 `git config --local core.hooksPath .githooks`。客户端 Hook 可以被绕过，不能替代 GitHub Push Protection 和必需的 PR 检查。

## 验证与回滚

```sh
sh -n .githooks/pre-commit .githooks/pre-push
git config --local --get core.hooksPath
.githooks/pre-commit
/path/to/actions/gitleaks-hooks/setup.sh --check
```

仓库中的 Hook 应具有执行权限。提交后，可通过 `git ls-files --stage .githooks/pre-commit .githooks/pre-push` 确认文件模式为 `100755`。运行 `gitleaks-hooks/test.sh` 可做隔离的行为测试；测试会创建临时本地仓库和合成测试令牌，不访问 GitHub，也不写入真实凭据。若还要离线测试安装流程，可将当前 macOS/Linux 平台的官方压缩包下载到某个目录，再执行 `TEST_RELEASE_DIR=/path/to/assets gitleaks-hooks/test.sh`；测试仍会校验固定的 SHA-256 值。

回滚安装时，只移除本脚本新建的 Hook，并恢复原来的 `core.hooksPath` 值。如果原先没有仓库本地配置，可使用 `git config --local --unset core.hooksPath`。脚本不会覆盖已有 Hook，也不会为新建 Hook 自动创建备份；不要删除其他工具的 Hook。

## 文件说明

- `setup.sh`：可独立执行的检查与修复脚本，内置两个 Hook 模板。
- `templates/pre-commit`、`templates/pre-push`：便于审阅的模板副本；测试会校验它们与脚本安装的内容一致。
- `test.sh`：安装流程和 Hook 行为的隔离回归测试。
