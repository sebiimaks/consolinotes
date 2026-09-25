# consolinotes

> **consolinotes** 是 [FSNotes](https://github.com/glushchenko/fsnotes) 的独立分支，与 FSNotes 项目及其作者无关，也未获其认可。此分支专注于 macOS，将应用界面改为终端风格。完整说明、许可证与第三方声明请见 [README.md](README.md)、[LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。下文为 FSNotes 原始 macOS 功能参考。

当前分支仅包含 macOS 应用。此前的 iOS 应用及分享扩展保存在[移除前的备份分支](https://github.com/sebiimaks/consolinotes/tree/codex/pre-ios-removal)。

## FSNotes

[English](README.md)
[繁體中文](README_zh_TW.md)

FSNotes 是本项目所基于的笔记管理器。

## macOS 应用

<a href="https://itunes.apple.com/app/fsnotes/id1277179284">
	<img src="https://fsnot.es/img/badge-download-on-the-mac-app-store.svg" alt="">
</a>

<img src="https://raw.githubusercontent.com/glushchenko/fsnotes/master/code.png" alt="macOS FSNotes" style="max-width:100%;">

### 主要功能

- **优先支持 Markdown**。也支持任何纯文本文件。
- **快速且轻量**。能够流畅处理 10k+ 个文件。
- **随时随地访问**。与 iCloud Drive 或 Dropbox 同步。
- **多文件夹**存储。
- **键盘为中心**。受 [nvalt](https://brettterpstra.com/projects/nvalt/) 启发的控件和快捷键。
- **代码块内语法高亮**。支持超过 170 种编程语言。
- **内联图片**支持。
- 使用**标签**进行组织。
- 使用 `[[双括号]]` 进行**跨笔记链接**。
- **弹性两窗格视图**。选择垂直或水平布局。
- 支持**外部编辑器**（更改会与 UI 实时同步）。
- **置顶**重要笔记。
- **快速复制笔记**到剪贴板。
- **暗黑模式**。
- AES-256 **加密**。
- **Mermaid 和 MathJax** 支持。
- 可选的**Git 版本控制**和**备份**。

## 许可证

FSNotes 使用 **Swift 5** 编写，采用 MIT 许可证开源。

## 特别鸣谢

@zcohan（https://soulver.app）提供了 Soulver 核心框架 https://github.com/soulverteam/SoulverCore，用于简单的内联计算。
