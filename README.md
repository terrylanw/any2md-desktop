# Any2MD Desktop

Any2MD 是一个面向 Windows 和 macOS 的本地办公文档转 Markdown 工具。Flutter 提供任务、编辑、预览和导出界面，Python sidecar 使用 MarkItDown 完成文档解析，文件内容不会上传到网络。

## 当前能力

- 支持 DOCX、XLSX、PPTX、文本型 PDF、TXT、CSV、HTML
- 多文件拖放、串行转换、失败重试和任务取消
- Markdown 轻量编辑、查找、撤销重做和安全预览
- UTF-8 导出、未导出草稿恢复、浅色/深色/系统主题
- worker 超时和崩溃恢复，不要求最终用户安装 Python

首版不支持 OCR、旧版 `.doc/.xls/.ppt`、RTF、ODF 和 Office 内嵌图片提取。

## 开发环境

- Flutter 3.44.7 / Dart 3.12.2
- Python 3.12 和 uv
- Windows：Visual Studio 2022，安装 “Desktop development with C++” 工作负载
- Windows：启用 Developer Mode，以允许 Flutter 插件创建符号链接
- macOS：当前稳定版 Xcode 和 Apple 命令行工具

依赖安装：

```powershell
flutter pub get
Set-Location converter
uv sync --dev
```

开发运行时，应用会使用仓库内的 `converter/worker.py`。如果 Python 3.12 不在 PATH 中，设置：

```powershell
$env:ANY2MD_PYTHON='C:\path\to\python.exe'
flutter run -d windows
```

也可以通过 `ANY2MD_CONVERTER_PATH` 指向已经打包的 worker 可执行文件。

### AI 驱动调试

项目支持 Dart and Flutter MCP server 对运行中的桌面应用截图、点击、输入和滚动。仅在需要 AI 操作界面时启用 Flutter Driver 扩展：

```powershell
flutter run -d windows --dart-define=ENABLE_FLUTTER_DRIVER=true
```

macOS 将设备名替换为 `macos`。不要在发布构建中设置该开关。Driver 模式默认保留真实键盘输入；MCP 需要调用 `enter_text` 时，可以先通过 `set_text_entry_emulation` 临时开启文本输入仿真，完成后再关闭。

## 验证

```powershell
flutter analyze
flutter test
Set-Location converter
uv run pytest -q
```

## Windows Beta

安装 Inno Setup 6 后运行：

```powershell
.\scripts\build_windows.ps1
```

脚本依次打包 Python worker、构建 Flutter Release、复制 sidecar，并在 `installer/Output` 生成当前用户范围的 x64 安装包。没有 Inno Setup 时仍会生成可直接运行的 Release 目录。

## macOS Beta

在目标 Mac 上执行：

```bash
./scripts/build_macos.sh
```

PyInstaller 不能跨平台构建。公证前必须使用同一 Team ID 签名 app 内的 converter 二进制、Frameworks 和主 app，再启用 Hardened Runtime 进行 notarization。Apple Developer 凭据不保存在仓库中。

## 本地数据

草稿和轮换日志位于系统 Application Support 目录下的 `Any2MD` 子目录。日志单文件最大 2 MB，保留 5 个历史文件；日志不记录 Markdown 正文。导出成功或移除任务后，对应草稿会被删除。
