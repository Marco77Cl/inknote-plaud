# InkNote Studio 本地转文字

更新与原生界面验收：2026-10-18。

## 使用

打开 `apps/inknote-studio/build/InkNote Studio.app`。

- 设备录音：先下载录音，再点该行「转文字」。
- 已在 Mac 的 WAV：进入「本地录音与文字」→「导入 WAV」→「转文字」。导入会复制录音，原文件保留。
- 选择中文、英语或自动识别，点击「开始转写」。可取消；完成后结果自动保存。
- 每段文字可编辑；点击「保存修改」或关闭文字窗口会保存。可导出 TXT 或 SRT。SRT 保留识别时间码，使用编辑后的文字。
- 文字保存在录音旁的 `<文件名>.wav.inknote.json`；再次打开本地库可以查看。若该文件无法读取，软件保留它，不用新结果覆盖。
- 默认录音库：`~/Downloads/InkNote/`。可使用「更改位置」，选择后会记住目录。

## 网络与处理位置

模型及引擎已经打包在应用内，无需账号或 API Key。转写没有网络请求，不上传音频，也不依赖录音设备保持在线。家庭 Wi-Fi、InkNote 热点和断网状态均不影响已下载文件的转写。

下载阶段仍需要 Mac 与设备之间可达。同名 Wi-Fi 不保证同一网段。当前设备在传输模式提供热点，已有 STA 网络保留；局域网访问受路由器及 VPN 配置影响。

## 实现

- Whisper.cpp v1.8.7，固定源提交 `48f628a84833905ee4a0658ee6d4a5c915ce1997`。
- Whisper small 多语言模型，官方仓库列出的 SHA-1 `55356645c2b361a969dfd0ef2c5a50d530afd8d5` 已校验。
- Apple Silicon 本地 CPU / Accelerate，4 线程；应用内静态引擎只依赖 macOS 系统库。
- 代码：`apps/inknote-studio/Transcription.swift`；构建：`apps/inknote-studio/build.sh`。
- 完整环境重建入口：`bash scripts/setup_local_transcription.sh`。首次准备需要网络，运行转写不需要。
- 上游文档：https://github.com/ggml-org/whisper.cpp/tree/v1.8.7

## 验收证据

- 本机原生 UI：导入已有设备录音 `rec_6822a787.wav`（约 25 秒），执行中文识别，显示文字与时间码，修改标点并保存，关闭后重新打开仍保留。
- 实际点击导出 TXT、SRT；磁盘文件与已保存编辑内容一致。导入副本与原始 WAV 的 SHA-256 相同。
- 测试文件：`recordings/transcription-validation/studio-edited.txt`、`studio-edited.srt`。
- 原生验收记录：`logs/inknote-speech-native-acceptance.json`。
- 自动测试：`tests/check_transcript.swift`，结果 `logs/inknote-transcript-tests.log`；覆盖时间码、字幕、JSON 编辑往返、空结果、保存重开、损坏文字文件保留。
- CLI 实录测试：`logs/whisper-recording-test.log`；应用打包：`logs/inknote-speech-build.log`。

边界：已新增说话人区分与会议纪要，详见 [会议功能](meeting-features.md)。真实验收为短录音，不代表已评估长会议准确率。人名、数字、专业词汇仍需核对。本轮没有重新验收真实 Wi-Fi 文件下载，也没有改变设备固件。
