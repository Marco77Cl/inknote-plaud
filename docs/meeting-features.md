# 本地说话人区分与会议纪要

实现与原生界面验收日期：2026-10-18。

## 使用流程

1. 在 InkNote Studio 的「本地录音与文字」打开已转写录音。
2. 点击「区分说话人」。默认自动估计人数；若人数已知，先选择 1–8 人。标签是声音分组，不是身份识别。
3. 每段上方可直接修改说话人标签，例如「主持人」。手动修改的标签在重新区分时保留。
4. 若同一转写段包含多个声音，系统显示「待确认」，不会强行猜测属于谁；展开「声音分段」可查看模型分出的时间范围。旧转写不会被自动拆句或改写。新转写使用较短段落以改善对应关系。
5. 点击「生成会议纪要」。在「会议纪要」页查看讨论要点、明确决定和待办，每条附原文段落与文字。
6. 要点可编辑，使用「保存修改」保存，或「导出纪要 Markdown」。导出包含原文依据。重新生成会用新结果替换现有纪要。
7. 修改原文或说话人后，旧纪要仍保留，但显示需要重新生成的提示。处理中可取消，不会覆盖已有纪要。

## 本地处理与边界

- 所有音频与文字分析在 Mac 本机运行；模型首次安装需要联网，日常使用不需要账号或 API。
- 说话人：sherpa-onnx 1.13.8，pyannote segmentation 3.0 ONNX + 3D-Speaker ERes2Net 中文模型。
- 纪要：Qwen2.5-7B-Instruct Q4_K_M，llama.cpp 固定提交 `797de63b2fa7396dcc8caca76834c699ac84e1c3`，CPU / Accelerate。
- 自动人数、远场声音、背景电视和重叠讲话可能导致标签错误，允许设置人数和手动纠正。现有短录音曾出现人数偏多。
- 纪要是 AI 草稿；原文引用校验只保证引用确实存在，不等于摘要事实全都正确，仍需核对。
- 长文字按顺序分块处理并汇集要点，不丢弃尾部内容；当前不跨块合并议题，可能存在重复或缺少全局归纳。
- 本轮不修改设备固件、原始录音，不提供云端发送、身份识别或自动执行待办。

## 来源与复现

- https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/
- https://github.com/k2-fsa/sherpa-onnx/blob/master/python-api-examples/offline-speaker-diarization.py
- https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF
- 完整安装构建入口：`bash scripts/setup_meeting_features.sh`，依赖项目已有 `tools/host-venv` 及 Xcode。
- Qwen 原始分片固定 revision `bb5d59e06d9551d752d08b292a50eb208b07ab1f`，逐片校验 SHA-256 后使用官方工具合并。
- 本地代码：`apps/inknote-studio/MeetingFeatures.swift`、`native/speaker_cli.cc`、`native/summary.gbnf`。

## 自动测试与模型验证

- `tests/check_meeting.swift`：旧 JSON 兼容、时间重叠标签、手动标签保留、纪要过期提示、无效引用拒绝、分块覆盖完整性。
- `tests/check_meeting_cancel.swift`：实际子进程取消与忙碌状态恢复；这是模拟等待进程的取消测试。
- `tests/check_transcript.swift`：原转写功能回归。
- 官方中文四人样例，固定人数模式已执行，输出 `recordings/transcription-validation/four-speakers.json`；这不是真实长会议准确率评测。

## 本轮最终结果

- 最终应用版本 0.3，所有运行依赖和模型已内置；安装包较大（约 5 GB），日常运行无需网络。
- 原生 UI：打开旧版实录转写 → 重新自动区分 → 显示「说话人 1」→ 生成纪要 → 测试录音没有明确会议要点 → 导出 Markdown，保存文件与界面一致。
- 含决定和待办的明确事实样例：保留五人试用、下周一开始，以及小李周五前整理说明；引用编号校验通过。该样例是构造的功能测试文本，不是真实会议准确率测量。
- 禁止网络的进程沙箱下运行摘要成功，证明推理不依赖联网。
- 自动聚类最终阈值 0.7：四人公开样例自动估计为五人；指定四人时输出四组。已有设备短录音输出一人。自动模式明确标为试验，建议已知人数时手动指定。
- 原生验收：`logs/meeting-native-acceptance.json`；正向摘要样例：`logs/summary-fixture-acceptance.json`；运行包校验：`logs/meeting-runtime-manifest.json`。
