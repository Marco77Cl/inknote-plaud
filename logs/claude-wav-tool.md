已创建 `scripts/inspect_wav.py`（未运行任何命令）。

**实现要点**

- **仅标准库**：`wave, struct, math, json, argparse`（外加 `sys, os`，均属标准库）。
- **六项验收**：`comptype == NONE`、`16000 Hz`、`sampwidth == 2`、`channels == 1`、`nframes > 0`、`实际读取字节数 == nframes * channels * sampwidth`。
- **分块读取**：`readframes(65536 // frame_size)` 循环，峰值/RMS/零样本用 `struct.iter_unpack("<h", ...)` 逐块累加，不整段载入内存；带 `carry` 处理截断残留字节。
- **长度一致性**：比对 `data_bytes_read` 与 `data_bytes_declared`，另外统计 `leftover_bytes`（不足一帧的尾部字节），并捕获截断时 `wave`/`EOFError` 提前中断的情况。
- **退出码**（`inspect_wav.py:44-54`，按优先级 1→2→3→4）：
  `0` 通过 / `1` 无法打开或非合法 WAV / `2` 参数不符 / `3` 长度不一致 / `4` 帧数为零。失败路径同样输出结构完整的 JSON 到 stdout。
- **静音策略**：只写 `silence_suspected`（全零）与 `near_silence_suspected`（RMS < 1 LSB），并把说明放进 `warnings`；`mic_verified` 恒为 `false`——工具不冒充“MIC 通过”。静音本身不产生非零退出码，因为验收项是参数与长度。

**JSON 字段**：`format`（压缩方式/声道/采样率/位深/声明帧数与声明字节数）、`read`（实读帧数/字节数/残留/读取错误）、`duration_seconds` 与 `duration_declared_seconds`、`file_size_bytes`、`peak`/`peak_normalized`、`rms`/`rms_dbfs`、`sample_count`/`zero_sample_count`/`zero_sample_ratio`、`silence_suspected`、`mic_verified`、`checks`、`errors`、`warnings`、`ok`。

用法：`python3 scripts/inspect_wav.py <file.wav> [--compact]`（我未执行，需要的话你再跑）。
