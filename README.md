# Ysclmml Homebrew Tap

个人 Homebrew 安装源，目前支持以下产品：

- [NoteSpace（笔记空间）](https://github.com/Ysclmml/notespace)：本地 Markdown 与文本编辑器，适用于 macOS Apple Silicon。

## 安装

```sh
brew install --cask ysclmml/tap/notespace
```

当前 0.2.0 预览版尚未通过 Apple 公证。本安装源仅移除 NoteSpace 的下载隔离标记，不关闭全局系统安全检查；请在信任本仓库及发布者后安装。

## 升级

先保存文档并退出 NoteSpace，再运行；升级和重装保留应用数据。

```sh
brew update
brew upgrade --cask ysclmml/tap/notespace
```

## 卸载

先保存文档并退出 NoteSpace，再运行：

```sh
brew uninstall ysclmml/tap/notespace
```

普通卸载会移除应用，并将设置、最近文件、浏览记录和缓存移入废纸篓；不会删除笔记、工作区或图片。
