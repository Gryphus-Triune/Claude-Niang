# 参与开发

使用 Node.js LTS（建议 22 或 24）和 Windows PowerShell 5.1。运行测试不需要登录 Claude，也不会访问真实 Claude 账号。

```powershell
cd claude-niang
npm test
npm run test:windows
```

提交前运行两组测试。模拟响应放在 `claude-niang/tests/fixtures`；新增样本请移除 Cookie、令牌、邮箱、真实组织名称和编号。不要提交 `installation.json`、运行数据、登录配置或个人图片。

额度只能由明确的用户操作读取。请为启动、恢复窗口、切组织、登录状态改变、并发请求和失败路径添加相应验证，避免重新引入后台查询。

在仓库根目录打包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

构建只复制 `claude-niang/runtime/install-files.json` 白名单里的文件，生成 Claude 桌面扩展，以及 `dist` 中的发布 ZIP 与 SHA-256 校验文件。安装记录、日志和账号数据不会进入发布包。更新仓库里的 `Claude桌面扩展/claude-niang-usage.mcpb` 时，用发布 ZIP 里同名的文件替换。

`claude-niang/runtime/mcp.mjs` 是 MCP 服务的唯一源码。构建会把它复制成扩展内的 `server/index.mjs`，把根目录的 `LICENSE` 复制进扩展，并从 `package.json` 同步扩展版本。保持服务源码中的版本常量与包版本一致。

默认形象是 `claude-niang/assets/claude-niang.png`。墨镜位置记在同目录的 `claude-niang.glasses.json` 里，其中的 SHA-256 必须和图片一致；换图后要重新标定位置和校验值，否则律动时不显示墨镜。

Windows 10、ARM64、微软商店版 Claude 和多屏高 DPI 需要实机反馈。报告问题时提供系统版本、Node 版本、安装路径是否含特殊字符和错误码即可，不要公开登录文件或完整的浏览器配置目录。
