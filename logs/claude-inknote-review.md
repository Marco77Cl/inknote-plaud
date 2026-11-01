已读完两份文件（`main.c` 284 行、`es8311_bsp.c/h`）。以下 5 条是从代码文本可直接确证的问题，按严重度排列。

---

**1. I2S 主时钟倍数三方不一致 → 采样率/音高错乱（格式错误）**
`es8311_bsp.c:147` 用 `EXAMPLE_MCLK_MULTIPLE`（`es8311_bsp.h:18` = 384）初始化，MCLK = 16000×384 = 6.144 MHz；但 `es8311_bsp.c:56` 的 `mclk_div = 0`（注释自述"0 表示用默认 256"）意味着 ES8311 内部按 MCLK = 256×fs 计算。`main.c:94` 在此时调用 `es8311_codec_init()`，codec 寄存器按 256 倍率写入，而实际时钟是 384 倍 → ADC/DAC 内部时钟与 ws/采样率相差 1.5 倍。随后 `main.c:99,103` 又用 `I2S_STD_CLK_DEFAULT_CONFIG(RATE)`（`mclk_multiple` 默认 256）对 **rx** 通道重配时钟，把 MCLK 改成 4.096 MHz，而 tx 通道（同一 `I2S_NUM_0`）仍是 384 的配置。：单声道/16-bit 的 WAV 头（`main.c:66-67`）与实际采集时钟不匹配，录出的 wav 采样率是错的。

**2. 只 disable rx 就重配通道 → `ESP_ERROR_CHECK` 可能在启动时 panic（编译/运行时致命）**
`main.c:102-104` 只 `i2s_channel_disable(rx_handle)` 后调用 `i2s_channel_reconfig_std_clock/…slot`，而 `es8311_bsp.c:151-152` 在 `i2s_driver_init()` 里已经 `i2s_channel_enable(tx_handle)`，tx/rx 是同一 I2S 端口的两个通道。当 tx 处于 enable 状态时重配共享端口时钟，驱动返回错误即被 `ESP_ERROR_CHECK` 直接 abort —— 会表现为"上电即重启"，且因为发生在 `configure_audio()` 里，`fail()` 那条优雅路径（`main.c:277`）根本走不到。同处 `slot.slot_mask`（`main.c:101`）改写的是 `I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG` 的返回值，而 `esp_codec_dev_open(record_dev_handle, …)` 已在 `es8311_bsp.c:110` 按 mono 打开，两处配置没有任何一致性校验。

**3. 录音丢样：消费端一旦停顿，整段录制被判定失败/尾部 DMA 数据被丢弃**
- `main.c:122-124`：ring 只有 128 KB（≈4 s 音频），`xStreamBufferSend(..., 0)` 一旦放不下就 `capture_failed=true; break;`——已采集的数据全部作废。而 `capture_task` 优先级 8 高于 `recorder_task` 的 5 且两者都 pin 在 core 1（`main.c:163`、`main.c:280`），消费端任何停顿都会迅速填满 ring。
- 停录时 `capture_task` 读完最后一个 buffer 就跳出循环并立即 `i2s_channel_disable(rx_handle)`（`main.c:127`）；此刻 RX DMA 描述符里**已接收但尚未被 `i2s_channel_read` 取走**的数据被直接丢弃，而 recorder 的排空逻辑（`main.c:193`）只能看到已经进过 ring 的字节，看不到这部分 → 每次停止固定丢失尾部一截 DMA 数据（并按 `main.c:200` 的 `st_size==bytes+44` 校验，文件本身"看起来"完整）。

**4. 实时路径上的阻塞式 IPC + 无会话绑定的全局停止标志（任务竞态）**
- `publish()` 在 `main.c:57` 用 `xQueueSend(display_queue, &v, portMAX_DELAY)` 阻塞发送，队列深度只有 8（`main.c:270`），而 `display_task` 每条消息都要跑完整套 EPD 刷新（`main.c:218-233`，含 `EPD_Init_Fast/EPD_Display/EPD_Sleep`，单帧可达秒级）。`recorder_task` 和 `app_main`（`main.c:281`）都走这条路径：队列一满，录制线程就被挂住，配合第 3 条的 128 KB ring 必然溢满 → 录制判失败。
- `stop_requested` 是全局单标志：`main.c:239` 的 `stop` 分支**没有任何状态守卫**（`start`/`toggle` 有，`stop` 没有），可在 READY/SAVING/按键抖动窗口写入；而 `main.c:241` 在 `xTaskNotifyGive` 前才清零。两个动作分别由 `controls_task`（`main.c:282`，未 pin 核、优先级 4）和 `recorder_task`（core 1、优先级 5）执行，存在"新会话刚被 notify，随即被上一次按键写入的 stop 立刻终止 → `bytes==0` → 直接进 ERROR"的窗口。

**5. 任何一次失败后无法再录音（状态机缺陷）**
`fail()`（`main.c:59`）把状态置为 `ERROR_STATE`，而 `command()` 的启动条件只接受 `READY || COMPLETE`（`main.c:240`）。因此 `main.c:153`（建文件失败）、`164`（capture 任务创建失败）、`209`（保存失败）中任意一条路径触发后，设备在断电重启前**再也无法开始录音**，按 dial 完全无反应。

---

**两点需要如实说明：**

- 你点名的"保存失败却显示 COMPLETE"，我在 `main.c:195-209` 逐条核对后**没有找到确证的漏洞**：`ok` 同时要求 `write_ok`、`!capture_failed`、`!dma_overflows`、`bytes>0`、`!(bytes&1)`、`header_ok`、`flush_ok`、`sync_ok`、`close_ok`，并且 `rename` 与 `stat(st_size==bytes+44)` 校验都在 `publish(COMPLETE)` 之前；短写也会被 `main.c:176` 捕获。唯一沾边的是 `main.c:155` 在失败时仍把 `view.file` 填成最终 `.wav` 名，而数据实际在 `.part` 中（文案误导，非误报成功）。
- 屏幕 API 的编译错误我**无法确证**——`Paint_*` / `EPD_*` / `Font24` / `EPD_SIZE_MONO` 全部来自 `epaper_port.h`，按你的要求我没有读该文件。最可疑的是 `main.c:232` 的 `EPD_Init_Fast()` 无参调用：Waveshare 系列 2.13"/4.2" 的 `EPD_Init_Fast(mode)` 需要一个刷新模式参数，无参即"参数太少"编译失败；`main.c:220` 的 `Paint_SetScale(2)` 紧跟在 `Paint_NewImage` 之后（后者内部已置 Scale=2）属冗余而非错误。需要放开 `epaper_port.h` 才能定论。
