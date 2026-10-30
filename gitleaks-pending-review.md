# actions gitleaks 检查初步分析（2026-10-30）

- 扫描口径：`gitleaks detect --log-opts=--all`（全 refs），gitleaks 8.30.1 默认规则。
- 结果：4 命中 / 4 唯一指纹，全部进入 `.gitleaksignore` 基线；**新泄漏不在基线内，hook 仍会拦截**。
- 本仓库为 gitleaks-hooks 模板源仓，pre-commit/pre-push hooks 已内置（8de41b3）。

## 汇总

| 类别 | 指纹数 | 在 HEAD | 处置 |
| --- | --- | --- | --- |
| 误报-CI 缓存键名 | 4 | 4 | 安全 |

## 误报-CI 缓存键名（4）— 安全

均为 action 测试/文档中的缓存键字符串（lindera 缓存版本键、rust-toolchain 缓存键），非凭据：

| # | 位置 | 内容 | 链接 |
| --- | --- | --- | --- |
| 1 | `README.md:26` | `lindera-cache-key: lindera-0.43.1` | [link](https://github.com/pingkaicloud/actions/blob/main/README.md#L26) |
| 2 | `nas-cache/test.sh:140` | `lindera_key="lindera-0.43.1-<lock-hash>"` | [link](https://github.com/pingkaicloud/actions/blob/main/nas-cache/test.sh#L140) |
| 3 | `setup-rust-toolchain/test.sh:85` | `export LINDERA_CACHE_KEY=lindera-0.43.1-test` | [link](https://github.com/pingkaicloud/actions/blob/main/setup-rust-toolchain/test.sh#L85) |
| 4 | `setup-rust-toolchain/test.sh:376` | `RUST_TOOLCHAIN_CACHEKEY=20260130replacement` | [link](https://github.com/pingkaicloud/actions/blob/main/setup-rust-toolchain/test.sh#L376) |

## hooks 使用说明

开发者克隆后执行一次即可启用：

```
curl -fsSL 'https://raw.githubusercontent.com/pingkaicloud/actions/main/gitleaks-hooks/setup.sh' | sh -s --
```
