# 算法修改后的验证

- 修改 PDF/OCR 识别、金额/日期规则、截图去重、支付关联或费用汇总后，运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-regression.ps1`。
- 查看本轮 `report.md`、`suites.json` 和 `changes.json`。如有新增失败，应定位原因；报告中区分已有缺陷、新增回归和执行环境故障。不能仅凭单元测试通过宣称真实材料全部通过。
- 本地人工标注位于 `.local/regression-dataset/v1/dataset.json`，原件副本、识别结果和报告均属于私有测试数据，不提交 Git 或随 Release 发布。
- 不把算法当前结果自动写回预期。标注确实错误时记录原因并提升数据集版本。
- 初始已知失败是 `file:didi-a-payment` 和 `case:didi-a-known-failure`：8.76元截图金额未识别及关联失败。修复后这两项应变为通过，不继续豁免；其他失败不能自动列为已知失败。
- 测试只能使用独立临时工作区，不操作正式差旅记录或真实邮箱凭据。不并发执行Flutter/Dart构建或回归，以免原生构建缓存冲突。
- 开源克隆中没有本地私有集时，运行可用的单元测试，并明确报告真实材料验证未执行；不得用空数据集生成通过结论。数据集格式及使用方法见 `testdata/README.md`。
