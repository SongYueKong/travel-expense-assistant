# 第三方软件声明

本项目原创代码采用 GPL-3.0-only；以下依赖、运行库和平台生成代码仍受各自原有许可证约束。

| 组件 | 用途 | 许可信息位置 |
| --- | --- | --- |
| Flutter / Dart 及 Flutter 插件 | 桌面界面和客户端运行 | 免安装包 `data/flutter_assets/NOTICES.Z`；依赖包自身 LICENSE |
| Drift / SQLite 及 Dart 依赖 | 本地数据库和业务支持 | Flutter 汇总声明、各依赖自身 LICENSE；SQLite 自身发布声明 |
| CPython | 本地引擎运行 | `runtime/python/LICENSE.txt` |
| pypdf、Pillow、ReportLab、charset-normalizer、pypdfium2 / PDFium | PDF、图片、文字识别前后处理与预览 | `runtime/python/Lib/site-packages` 中各组件的许可和 `.dist-info` 许可目录 |
| Microsoft Visual C++ Redistributable | Windows 原生运行支持 | Microsoft 对应版本运行库的许可；这部分不适用本项目 GPL |
| Windows OCR 和系统字体 | 本地识别和文字显示 | 随操作系统提供；适用 Microsoft 相应条款，项目不分发 Windows OCR 或系统字体文件 |

Windows 平台工程中保留的 Flutter 模板版权声明继续有效。完整依赖版本见 Dart 的 `pubspec.lock` 和免安装包的 `version.json`；Python 依赖范围见 `engine/requirements.txt`。

发布脚本保留随依赖提供的第三方许可文件；本文件用于索引，不替代各组件的完整许可条款。
