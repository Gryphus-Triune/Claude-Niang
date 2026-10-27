# 参与开发

使用 Node.js 20 或更新（建议官网 LTS 版）和 Windows PowerShell 5.1。运行测试不需要登录 Claude，也不会访问真实 Claude 账号。

## 运行检查

在仓库中的 `claude-niang` 目录执行：

```powershell
cd claude-niang
npm test
npm run test:windows
```

提交前运行这两组检查。模拟响应放在 `claude-niang/tests/fixtures`；新增样本请移除 Cookie、令牌、邮箱、真实组织名称和编号。

额度只能由明确的用户操作读取。涉及启动、恢复窗口、切换组织、登录状态改变、并发请求或失败路径的修改，应验证不会引入后台查询。不要把接口没有返回的窗口或已过重置时间的旧值当成当前剩余额度。

GitHub Actions 配置在 `.github/workflows/ci.yml`，在 Windows 上检查 Node.js 20、22、24 并试打包。通过情况以对应提交的 [Actions 运行结果](https://github.com/Gryphus-Triune/Claude-Niang/actions)为准。

## 生成干净发布包

在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

构建使用 `tools/release.mjs` 的文档清单、`claude-niang/runtime/install-files.json` 的程序白名单及测试文件，生成桌面扩展、内部文件校验表，以及 `dist` 中的以下文件：

- `claude-niang-v版本号-windows.zip`
- `claude-niang-v版本号-windows.zip.sha256`

发布前解压检查：主程序、默认资源、WebView2 组件和许可、桌面扩展、README 引用的文档与图片应齐全；`installation.json`、`install-log.txt`、运行日志、`state`、`webview`、缓存、登录配置和个人自定义资源应排除。发布附件使用构建输出，保留其文件名和校验文件。

不要提交机器上的安装记录、日志、账号数据或个人图片；它们也不应进入源码归档。`.gitignore` 只对未跟踪文件生效，已经被 Git 跟踪的文件需要另外从仓库中移除。

桌面扩展由构建生成，随发布 ZIP 和 Release 提供，不需要把生成的 `.mcpb` 放进仓库。新增文档或许可资源后，同步检查 `tools/release.mjs` 的白名单，确保发布 ZIP 中的 README 链接、图片与许可文件齐全。

发布普通版本时，先更新 `claude-niang/package.json`、README 的当前版本和 CHANGELOG 中对应的章节，再从包含这些更改的提交创建 `vX.Y.Z` 标签。仅整理同一功能版本的源码和发布包时，可使用 `vX.Y.Z-repack.N` 标签，并在 CHANGELOG 中添加对应的 `X.Y.Z-repack.N` 章节。`.github/workflows/release.yml` 会核对版本、运行检查、打包并创建 Release。不要移动已经公开的版本标签；发布前确认标签指向预期的源码提交。

## 扩展与资源

`claude-niang/runtime/mcp.mjs` 是 MCP 服务源码，和后台共享 `runtime/shared.mjs`。构建会将这两个文件复制进扩展的 `server/`，把根目录 `LICENSE` 复制进扩展，并从 `package.json` 同步扩展版本。扩展运行时读取 manifest 的版本；`shared.mjs` 不应引用扩展中不存在的本地模块。

默认形象、墨镜标定和资源维护见 [自定义资源说明](docs/customization.md)。内置语录的上游署名和许可见 `claude-niang/assets/quotes-LICENSE.txt`，发布包必须保留该文件。文档中的界面预览使用示例数据；添加效果展示时，说明它是实机截图、离线渲染还是示意图，并去除真实账号信息。

## 兼容性反馈

Windows 10、ARM64、微软商店版 Claude、多屏及混合 DPI 需要更多实机反馈。适配目标与实际验证结果应分别记录；测试通过不等同于全部登录、硬件和显示环境已验证。

报告问题时提供挂件版本、系统版本、Node.js 版本、安装路径是否含特殊字符、复现步骤与错误码即可。请去掉日志中的用户名、邮箱、个人路径和组织信息，不要公开登录文件、Cookie 或完整浏览器配置目录。
