# 差旅报账助手

一个面向个人差旅报账的 Windows 桌面工具，用于收集发票、核对支付截图、整理材料并导出报账 PDF。

开发者：**松月空**。当前版本：**0.1.11**，首次公开预发布，欢迎使用测试数据试用并反馈问题。

[下载 Windows 免安装版](https://github.com/SongYueKong/travel-expense-assistant/releases/tag/v0.1.11) · [反馈问题](https://github.com/SongYueKong/travel-expense-assistant/issues) · [GPL 3.0 许可证](LICENSE)

## 下载和运行

1. 在 Releases 中下载 Windows x64 的 ZIP 文件及可选的 `.sha256` 校验文件。
2. **完整解压**到普通文件夹，双击 `差旅报账助手.exe`。不要直接从 ZIP 内运行，也不要只复制 EXE。
3. 新建差旅，选择出差日期，从邮箱或本地添加材料，核对匹配结果后导出 PDF。

支持 Windows 10 / Windows 11 **64 位**。免安装包自带 Python、Flutter 运行文件、SQLite 和所需运行库，无需另装开发工具。截图识别使用 Windows 本地 OCR，需要系统具备中文识别语言。

本机已完成解压启动及独立目录自检；其他电脑的实际兼容性仍需试用验证。

## 功能

- **邮箱导入**：按时间范围获取邮件中的 PDF 附件，支持 QQ/Foxmail、163、126、yeah、139、新浪 `sina.com` / `sina.cn`、阿里个人邮箱 `aliyun.com`。邮箱需开启 IMAP，并使用相应客户端授权凭据；未开放自定义服务器和企业邮箱配置。
- **本地材料**：添加发票、行程单和手机支付记录截图；查看全部 PDF、发票信息、行程内容及截图。
- **分类核对**：按城际交通、住宿、市内交通组织。市内交通支持一张发票通过多条行程对应多笔支付。
- **匹配辅助**：金额默认容差 1.00 元；市内交通乘车或支付时间默认前后 150 分钟。候选按金额差、时间差排序，金额与时间无法区分、支付争用等情况交由人工处理。
- **优惠处理**：发票/行程金额与实付金额的差值，恰好等于截图明确标示的优惠时，可作为匹配依据；普通支出负号不会被当作优惠。
- **费用汇总**：票据核算额逐组取发票金额与关联支付净额的较小值。伙食补助按含首尾日期的出差天数计算，默认 100 元/天，可调整或关闭。
- **住宿证明**：发票销售方与支付收款单位不一致时，可补充 PDF、JPG/JPEG、PNG、BMP、WEBP 说明，或标记已有纸质证明。
- **出租车纸票**：手工录入金额和可选日期，可连续添加，后续补支付截图进行核对；导出带对应序号的横向 A4 粘贴框，每页一行四列。
- **异常处理**：查看未匹配支付和待处理材料，选择解决或忽略；导入时检测重复截图，保留已有材料，排除重复导入项。
- **差旅管理**：重命名、复制、删除；修改出差日期、补助和匹配设置。每条差旅保存为独立文件夹。

自动识别和匹配供整理材料使用，导出前请核对金额、收款单位和材料归属。完整匹配后可直接导出，人工复核标记可按需使用。

## PDF 排版

导出顺序为：**分类汇总表 → 发票及对应行程单/情况说明 → 出租车纸票粘贴页 → 支付截图**。材料使用对应编号，方便逐项核对。

在差旅界面“设置／更多 → 支付截图排版”中设置：

- A4 横向或纵向。
- 每页行数和列数，各 1～8；默认横向 2 行 4 列。
- 网格示意、恢复默认；图片等比例显示，尾页不足一页时保持相同格子尺寸。

排版偏好保存在本机，重启和新建差旅后沿用。导出 PDF 默认文件名包含当前差旅名称，保存时仍可修改。

## 数据位置和备份

免安装版默认数据目录：

```text
%LOCALAPPDATA%\TravelExpenseAssistant\Workspace
```

右上角“数据位置”可以查看或更换目录。更换后完全退出重开生效；不会自动搬移旧数据。

```text
Workspace/
├─ .local/                 # 全局设置、索引、缓存和迁移备份
└─ 差旅记录/
   ├─ 示例差旅_起止日期_编号/
   │  ├─ 差旅记录.json
   │  ├─ 发票/
   │  ├─ 行程单/
   │  ├─ 支付截图/
   │  ├─ 情况说明/
   │  ├─ 其他材料/
   │  └─ 导出文件/
   └─ .回收站/
```

备份单次差旅时，退出软件并复制整个差旅文件夹。JSON 保存完整记录，材料通过相对路径关联；不要只复制 JSON。恢复时放回“差旅记录”目录，启动后重新发现记录。全局偏好不随单次差旅文件夹迁移。

邮箱账号保存在本机设置中，授权码由当前 Windows 用户的凭据管理器保存。凭据不随差旅文件夹备份到其他电脑。发布包和源码仓库不包含开发者的差旅材料、个人邮箱账号、授权码或私有样本。

升级时，退出旧版本，将新 ZIP 解压到新的程序文件夹，再启动新版；同一 Windows 用户继续使用原数据目录。不要同时运行多个版本操作同一数据目录。

## 源码与开发

架构：Flutter 桌面界面、纯 Dart 匹配/金额规则、Python 本地 PDF/OCR 处理进程、Drift/SQLite 存储。当前提供 Windows 客户端；手机 App 尚未实现。

```text
apps/desktop/       Flutter 界面、导入/核对流程和持久化
packages/travel_core/ 纯 Dart 金额与匹配规则
engine/             Python PDF、OCR、邮箱及导出引擎
scripts/            开发启动、验证和免安装打包脚本
testdata/           可公开的合成规则和私有数据集格式说明
```

开发环境为 Windows x64、Flutter SDK 和 Visual Studio 的“使用 C++ 的桌面开发”组件，以及 Python 3.12。当前验证使用 Flutter 3.47.9 / Dart 3.13.7、Python 3.12.14。

在项目根目录准备 Flutter SDK，路径为 `.tools/flutter`；创建 Python 环境并安装依赖：

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python.exe -m pip install -r scripts/requirements-build.txt
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start-dev.ps1
```

开发版使用项目目录保存工作区，与免安装版的默认用户目录不同。

## 验证

在项目根目录执行 Python 和纯 Dart 规则测试：

```powershell
.venv\Scripts\python.exe -m unittest discover -s engine -v
.tools\flutter\bin\dart.bat packages/travel_core/test/rules_check.dart
```

Flutter 测试：

```powershell
cd apps/desktop
..\..\.tools\flutter\bin\flutter.bat pub get
..\..\.tools\flutter\bin\flutter.bat analyze --no-pub lib test tool
..\..\.tools\flutter\bin\flutter.bat test --no-pub
```

当前已验证 186 项 Flutter 测试和 90 项 Python 测试。另有私有真实材料回归集，其原件、人工标注和报告不会公开提交；开源克隆中没有这套材料。格式和执行方式见 [测试数据集说明](testdata/README.md)。有自行准备的本地数据集后，可运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-regression.ps1
```

## 已知限制

- 某些支付截图 OCR 仍会遗漏或误读金额。当前私有回归中有一张 8.76 元截图识别失败，导致对应行程也未自动匹配；36/38 的材料及规则检查通过，两项相关失败保留。可人工核对和录入。
- 扫描件、截图版式、邮箱附件格式和发票模板存在差异，无法保证全部自动识别。多笔候选和缺失信息仍需处理。
- 酒店说明的跨差旅历史库和多用户共享尚未实现；当前证明按差旅材料保存。
- Windows 10/11 的其他电脑验收正在开展；邮箱预设尚未逐一用真实账号验证。

## 重新打包

在开发依赖和 Windows 构建工具就绪后，从项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package-portable.ps1
```

版本号读取 `apps/desktop/pubspec.yaml`。脚本建立独立源码构建目录，执行静态检查和测试，收集运行库、自带 Python 及第三方声明，进行引擎/SQLite/实际 EXE 启动自检，然后生成 `output/releases` 下的 ZIP、SHA256 和包内文件清单。

源码由 Git 管理，免安装 ZIP 作为 GitHub Release 附件发布。私有材料、凭据、测试报告和本机诊断文件不进入仓库。

## 许可证与支持作者

Copyright (C) 2026 松月空。本项目原创代码采用 **GNU GPL version 3 only（GPL-3.0-only）**，完整条款见 [LICENSE](LICENSE)。第三方依赖和生成代码保留各自的许可证，见 [第三方声明](THIRD_PARTY_NOTICES.md)。

欢迎提交 Issue、改进代码，或通过 Star 支持项目。赞助链接待作者提供后再公开添加。
