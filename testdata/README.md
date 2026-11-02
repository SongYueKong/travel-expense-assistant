# 本地算法回归数据集

在项目根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-regression.ps1
```

默认依次运行 Python 引擎单元测试、Flutter 单元测试，然后使用真实 Python 识别引擎与 Dart 导入/匹配/汇总逻辑验证材料。不连接邮箱，不读取授权码，不启动或改写正式差旅数据库。

仅快速运行真实材料与规则数据集：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-regression.ps1 -SkipUnitTests
```

## 本地文件

真实数据集在 `.local/regression-dataset/v1/`，包含 `assets/` 原材料副本和 `dataset.json` 人工预期。此目录已经被 `.gitignore` 排除，禁止随开源项目、截图或 Release 公开。原始“示例数据”不依赖本地临时目录，复制后的数据集可以独立备份；备份整个 v1 文件夹即可。

可用 `-Dataset D:\本地测试集\v2` 指定另一套数据。公开仓库只保留执行器、说明和本目录的纯合成 `rules.json`；克隆代码不会包含私人样本。无本地数据集时脚本明确报错，不会把缺失样本当成全部通过。

当前版本1.1.0：16份真实材料（9份PDF、7张截图）、12个组合场景、10个合成规则场景，共38个数据集检查；高德打车发票/行程单及缺支付场景已追加。涵盖48元金额误读、酒店开票日期与销售方、两条/五条行程完整性、截图去重、混合类别汇总、出租车可选日期与取小值，以及150分钟正负边界、超界一秒、优惠解释、金额优先、时间辅助和争用。

金额一律使用整数分。场景中的出租车使用隔离测试输入，不表示真实报销归属。

## 报告与失败

每次报告写入 `.local/regression-reports/时间戳/`，不会覆盖历史报告：

- `report.md`：逐项通过/失败，失败字段的预期值与实际值。
- `report.json`：便于脚本读取的结果、数据集版本、源材料清单哈希及关键算法源码哈希。
- `actual.json`：本轮真实OCR、PDF解析、关联及导出阻断原因，含私人信息，仅保存在本机。
- `suites.json`：Python、Flutter及数据集执行退出码，是否跳过单元测试。
- `changes.json`：与上一次报告相比，哪些失败变为通过、哪些通过变为失败；样本或标注改变时明确标记不可直接比较。
- `python-tests.log`、`flutter-tests.log`、`dataset-run.log`：执行日志。

`latest.json` 在报告根目录指向最近一次执行目录。所有检查通过退出码为0，任一检查失败返回非零。材料哈希改变、材料丢失、越界路径或运行环境失败，也会阻断并记录，不会自动修正预期。

当前有一项已知识别缺陷：8.76元截图没有金额候选，同时影响其行程组合匹配。因此当前基线预期38项中36项通过、2项失败；失败保留真实正确金额876分，后续修复后应自然转为通过，不能将预期改成null来“修绿”。

## 扩展与维护

`dataset.json` 顶层为 `schemaVersion: 1`、`id`、`version`、`files`、`cases`。

每个 `files` 条目包含唯一 `id`、`file`（例如 `assets/new-payment.jpg`）、`sha256`、`title`、`expected`。预期使用点分字段，例如 `ocr.paymentCandidate.cents`、`document.issueDate`、`document.trips.1.cents`。源材料先人工核对，再写入预期；不要把现有程序输出直接当答案。

每个 `cases` 条目用 `inputs` 引用材料ID，可设置 `toleranceCents` 和 `taxis`（金额cents、可选日期date）。`expected` 可检查组数groups、完整组数matched、重复支付duplicatePayments、未匹配支付unmatchedPayments、导出就绪exportReady、核算totalCents、分配assignments和住宿单位hotelSame。这里只验证导出清单和总额；PDF像素及排版由引擎布局测试和必要的人工视觉检查负责。

补充材料时将其复制到 `assets/`，填入SHA256和人工答案，提升数据集版本。材料哈希可用 `Get-FileHash -Algorithm SHA256 文件路径` 获取。算法改动时不更改预期；确属标注错误时记录理由再修订版本。

执行器自身可运行 `.venv\Scripts\python.exe scripts/verify-regression-harness.py` 验证：正确预期必须通过，故意错一分和错误材料哈希必须失败。该检查仅操作临时数据集副本。

运行时使用独立临时工作区，真实材料每轮重新识别一次，同轮多个组合复用该轮识别结果以节约时间。测试前后校验材料摘要，临时材料在执行结束后清理，报告和原件副本保留。不要同时执行多个Flutter/Dart构建或回归，以免原生构建缓存冲突。
