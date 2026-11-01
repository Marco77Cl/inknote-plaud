以下为只读审查结论（未修改任何文件）。

## 1. 引脚映射
**02_Mic_test（板型 S3_ePaper_3_97）** `components/codec_board/board_cfg.txt:86-89`：i2c sda=41/scl=42；i2s mclk=13、bclk=14、ws=47、dout=48、din=21；`in_out: {codec: ES8311, pa: 39, use_mclk: 1, pa_gain: 6}`。I2C 常量在 `components/i2c_bsp/i2c_bsp.h:26-29`（SCL42/SDA41，400kHz）。`main/main.c:107` 只调 `i2c_master_init()`，**未调用** `i2c_devices_init()`。

**04_SD_Test** 无 I2C/音频代码。SD：`components/sdcard_bsp/sdcard_bsp.c:14-19` clk=16、cmd=17、d0=15、d1=7、d2=8、d3=18，4 线模式（`:50-57`）。屏：`components/epaper_port/epaper_port.h:12-20` SCLK=11、MOSI=12、CS=10、DC=9、RST=46、BUSY=3；SPI3_HOST、20MHz（`epaper_port.c:50,55`）。

**08** `components/es8311_bsp/es8311_bsp.h:24-30` 与上述 board_cfg 逐项一致（13/14/47/21/48，PA=39）；SD 与屏引脚同 04（`sdcard_bsp.c:14-19`、`epaper_port/epaper_port.h:12-20`）；I2C 同 02（`i2c_bsp.h:26-29`）。**无冲突**：GPIO13 在 02/08 是 I2S MCLK，而 03/06 系列把 13 当 SD 供电；02 的 `codec_init.c:646-655` 那段 `GPIO_NUM_13` 置 0 被 `#if defined CONFIG_IDF_TARGET_ESP32` 包住，S3 编译不生效，故不冲突。

## 2. MIC 单/双通道
- **02 用双通道**：`audio_bsp.c:91-96` 对 playback 与 record **同一份 fs**（16000Hz、channel=2、16bit）；`main.c:15-17` `RECORD_CHANNEL=2`，缓冲 = 16000×2×2×3 = 192000B（`:119` 用普通 `malloc`，日志却写 SPIRAM）。ES8311 走单 codec 分支（board_cfg `in_out`），`audio_bsp.c:26` 置 `reuse_dev=false`，于是录音/播放是两个独立 `esp_codec_dev`（`codec_init.c:462-469`），I2S 以 `I2S_CHANNEL_FMT_RIGHT_LEFT` 立体声建立（`codec_init.c:265`）。
- **08 用单通道**：`es8311_bsp.c:103-107` 录音 channel=1（注释“mono”），播放仍 channel=2（`:93-97`）；`main/page_audio/page_audio.cc:854-861` 录音强制 `slot_mode=I2S_SLOT_MODE_MONO`、`slot_mask=I2S_STD_SLOT_LEFT`，并对 rx 通道重配（`:883-888`）。
- 结论：同一 ES8311 硬件，08 按单声道采集、02 按双声道采集 → 02 的右声道为镜像/空，录制文件有效幅度约一半、体积翻倍。

## 3. 按键接口
- **02**：仅一键 `button_bsp.c:12` `USER_KEY_1=GPIO_NUM_0`，低有效（`:14`），内部上拉（`:59`）。事件位：单击 bit0（`:98`）、长按 bit1（`:128`）、弹起 bit2（`:132`）、双击 bit3（`:103`）。`main.c:29-37` 长按→录 3s，`:68-76` 单击→回放。电源键（PWR）代码整段注释（`:17-20,44-45,76-80,106-124`）。tick 定时器 `:88` 为 1000×5 µs=5ms，与注释一致。
- **08**：四键 `button_bsp.c:16-29` Up=4、Function=5、Down=6、Boot=0，均低有效、上拉（`:61-63`）。事件位分组 0-6/7-13/14-20/21-23。**缺陷**：Boot 的 `LONG_PRESS_START` 与 `LONG_PRESS_HOLD` 都置 bit23（`:292-296` 与 `:319-323`），且 `wait_key_event_and_return_code` 只能编到 24 位（`:369-377`），故“长按一次”和“长按保持”无法区分；`main.cc:403` 用 bit23（返回 23）进入设置页，`:322` 在息屏态也接受 23。

## 4. 电源芯片代码
- **08 有 AXP2101**，地址 0x34（`axpPower/src/REG/AXP2101Constants.h:3`）。`axp_prot.cpp:16-36` 把 `i2c_read_reg/i2c_write_reg` 包成回调，失败只打 `ESP_LOGE` 返回 -1；`axp_init()`（`:38-44`）`begin()` 失败仅打印 "Init PMU FAILED!"，**不返回错误**，`main.cc:458` 亦不检查，后续 `get_battery_power()`/`axp_pwr_off()` 仍会继续下发 I2C，失败会被静默吞掉。
- 关键寄存器动作：DC1=3300mV（`:53`）、ALDO1/2/3=3300mV（`:55-57`）、长按关机 4s（`:61`）、开机 1s（`:76`）、VBUS 限流 1500mA（`:47`）、预充 50mA/恒流 200mA/终止 25mA/目标 4.2V（`:101-106`）、低电告警 10% 与关机 5%（`:119-120`）、RTC 电池充电（`:116-117`）。关机流程先清音频再 `shutdown()`（`:275-282`），并在 `es8311_bsp.c:193` 显式拉低 PA(39)。
- **硬件无电池**：`main.cc:150-153` 对 `getBatteryPercent()` 用 `-1 → 20` 兜底；但充电/低电关机/fuelGauge 配置（`axp_prot.cpp:101-121`）在无电池时无对象，**AXP2101 必须由 VBUS 供电，否则 0x34 全 NACK**，而此处无 fallback。
- 02/04 完全没有电源芯片代码。

## 5. I2C NACK 线索
1. **08 存在未定义符号**：`es8311_bsp.c:13` `extern i2c_master_dev_handle_t es8311_dev_handle;`，但 08 的 `i2c_bsp.c:14-17` 只定义 rtc/shtc3/axp2101/qmi8658 四个句柄，`i2c_devices_init()`（`:53-83`）也只注册 0x51/0x70/0x34/0x6a，**没有 0x18**；该符号在 08 全工程只有这一处 extern，无定义 → 链接期未定义引用，ES8311 设备句柄实际不可用。
2. **02 可能在 port0 重复建总线**：`main.c:107` 先用 41/42 建 port0（`i2c_bsp.c:19-33`），随后 `audio_bsp_init`→`init_codec` 经 `check_i2c_inited(0)`（`codec_init.c:329-338`）判断；IDF≥5.4 时 `i2c_master_get_bus_handle` 能取到已有总线（`:104-113`）→ 正常复用；IDF<5.4 时 `get_i2c_bus_handle` 返回静态 `i2c_bus_handle[port]`（`:112`）为 NULL → 走 `_i2c_init` 对同一 port0 再 `i2c_new_master_bus`（`:77`），必得 `ESP_ERR_INVALID_STATE`，日志 "failed to initialize I2C master bus port 0"（`:79`），且随后 `.bus_handle`（`:412`）为 NULL，ES8311 读写全 NACK。
3. `i2c_bsp.c:113/134/155/176`（02 与 08 同构）用 `get_dev_handle(dev_addr)==NULL` 判断临时句柄，但临时句柄从不写回全局，条件恒真 → 每次读写都 `add_device` 再 `rm_device`，总线抖动大，重试可放大 NACK。
4. 无 `i2c_master_probe`、无地址扫描，NACK 只能从 `axp_prot.cpp:22/33` 的 `esp_err` 数字（ESP_FAIL=-1、ESP_ERR_TIMEOUT=0x107、ESP_ERR_INVALID_STATE=0x103）与 `:43` "Init PMU FAILED!" 反推。
5. 勿混淆：04 的 "The SD card was not found"（`sdcard_bsp.c:69-70`）是 SD 卡，不是 I2C NACK。
