# NoteSpace Homebrew Tap

用于安装 [NoteSpace（笔记空间）](https://github.com/Ysclmml/notespace) 的个人 Homebrew 安装源。目前提供 macOS Apple Silicon 的 `0.1.0` 预览版。

## 安装与升级

```sh
brew install --cask ysclmml/tap/notespace
```

安装包来自 [GitHub Release](https://github.com/Ysclmml/notespace/releases/tag/v0.1.0)，Homebrew 按 Cask 中的 SHA-256 校验下载。该版本使用 ad-hoc 签名，尚未 Apple 公证。

### macOS 启动说明

此个人安装源会在安装后自动移除 **NoteSpace.app 内的 `com.apple.quarantine` 下载隔离标记**，以避免因未公证而需要到系统设置中单独放行；普通的“来自互联网”提示也可能不再出现。应用内不增加说明窗口。

这是针对 NoteSpace 的应用级绕过，不代表 Apple 已验证应用。请仅在信任本仓库和发布者时安装。处理仅限 Homebrew 实际安装的 `NoteSpace.app`，保留其他扩展属性，不处理其他应用、笔记或设置，也不关闭全局 Gatekeeper、SIP 或 XProtect。它不保证绕过其他系统安全拦截，不是官方 `homebrew/cask` 的分发策略。

已有 Homebrew 安装需要应用此流程时，先保存文档并退出 NoteSpace，再运行：

```sh
brew update
brew reinstall --cask ysclmml/tap/notespace
```

重装保留设置和浏览记录。仅更新 tap 不会修改现有应用；直接下载 DMG 也不会执行此安装后处理。以后采用 Developer ID 签名并完成公证时，将恢复标准系统检查。

### 接管与升级

已有手动安装的同版本时，先保存并退出，然后可以尝试接管：

```sh
brew install --cask --adopt ysclmml/tap/notespace
```

接管要求应用与下载产物一致。若被拒绝，不使用 `--force` 覆盖；确认来源后，只将旧 `NoteSpace.app` 移到废纸篓，再正常安装，笔记和设置不动。

升级与重装前也请先保存并退出：

```sh
brew update
brew upgrade --cask ysclmml/tap/notespace
```

`brew upgrade` 和 `brew reinstall` 保留应用设置及浏览记录。

## 普通卸载即清理应用数据

**本安装源的普通卸载会同时清除应用设置、最近文件和浏览恢复记录，不需要另加 `--zap`。**

先保存全部文档并正常退出 NoteSpace，再运行：

```sh
brew uninstall ysclmml/tap/notespace
```

除了移除应用本体，还会将以下三个应用专属路径移入系统废纸篓，可从废纸篓恢复：

- `~/Library/Caches/app.markdownworkspace.desktop`
- `~/Library/Preferences/app.markdownworkspace.desktop.plist`
- `~/Library/WebKit/app.markdownworkspace.desktop`

不会删除 Markdown、工作区、代码或粘贴图片，不会强制结束未保存的编辑进程，不会修改全局系统安全设置。发现应用仍在运行、进程检查失败、路径被符号链接重定向或清理失败时会明确报错；不会静默宣称已清理。

这里的“干净卸载”指应用本体及上述明确列出的应用数据；不承诺删除 macOS 管理的日志、索引、备份、废纸篓内容，或 Homebrew 自己缓存的下载包。

## 维护与兼容性

- 不要把这三个路径直接改成 `uninstall trash:`：Homebrew 也会在升级/重装中执行该项。
- 自有 tap 通过卸载钩子精确识别 `brew uninstall`；其他操作保留数据。钩子依赖 Homebrew 的内部命令上下文与原生废纸篓接口，兼容性需要随 Homebrew 更新复验。无法确认上下文时保留数据并提示，不猜测为卸载。
- 安装钩子只移除实际 `NoteSpace.app` 内的下载隔离属性，不跟随符号链接到外部目标，不使用 `sudo`、改权限或删除其他属性作为回退。重复执行应无害，读取或删除属性失败必须报错。不要将处理范围扩大到整个应用目录或系统下载缓存。
- 这些 Ruby 代码仅供 Homebrew 读取，不给 NoteSpace 应用引入 Ruby 运行时或额外工具链。
- 新版本需上传新的 Release 附件，再更新版本与真实 SHA-256；不要覆盖既有版本附件。

隔离策略测试使用 Homebrew 自带的 Ruby，不需要安装测试依赖：

```sh
HOMEBREW_DEVELOPER=1 brew ruby test/notespace_policy_test.rb
HOMEBREW_DEVELOPER=1 brew ruby test/notespace_quarantine_test.rb
```

第一项拦截系统动作，验证安装/卸载各阶段的范围与失败行为；第二项只对运行时生成的临时目录执行真实 `xattr`，验证重复执行、属性保留及符号链接隔离，不操作已安装应用或真实用户数据。

官方参考：[Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)、[自建 tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)。
