# 文档同步说明

本文仓库的 `docs/` 目录会自动同步到 `wurishen/pyramid-android` 仓库。

## 工作原理

GitHub Actions Workflow `.github/workflows/sync-spec-to-android.yml` 会在以下时机触发：

1. **自动触发**：push 到 `main` 分支且 `docs/**` 有变更
2. **手动触发**：通过 GitHub Actions 的 `workflow_dispatch`

触发后将 `docs/` 目录完整复制到 Android 仓库的 `docs/` 并自动提交。

## 配置要求

### 1. 创建 Personal Access Token (PAT)

在 GitHub 上创建一个 PAT（Fine-grained 或 Classic）：

- **权限**：需要 `repo`（完整仓库访问权限），用于推送到 `pyramid-android`
- **作用域**：Classic token 需勾选 `repo`

### 2. 配置 Secret

在 **pyramid-ios** 仓库的 Settings → Secrets and variables → Actions 中添加：

| Secret 名称 | 值 |
|---|---|
| `ANDROID_SYNC_TOKEN` | 上一步创建的 PAT |

### 3. 验证

- 向 iOS 仓库 push 一个 `docs/` 下的文件变更
- 在 Actions 页面查看 `Sync docs to Android` workflow 运行情况
- 确认 Android 仓库的 `docs/` 已更新
