# 官方源码审查（主 Agent 复核）

来源：vendor/waveshare，commit 9b12d40731a80213b927ee8a421cae4082952819。
Claude 原始审查位于 logs/claude-source-audit.md；以下仅保留复核结论，原始报告不能直接当验收依据。

## 确认
- E-Ink：SCLK11、MOSI12、CS10、DC9、RST46、BUSY3。
- SDMMC：CLK16、CMD17、D0=15、D1=7、D2=8、D3=18。
- I2C：SDA41、SCL42。
- I2S：MCLK13、BCLK14、WS47、DIN21、DOUT48；PA39。
- 拨轮上/中/下：GPIO4/5/6；BOOT：GPIO0。
- 02_Mic_test：16 kHz、16-bit、channel=2，3秒192000字节 RAM buffer。不能把此缓冲直接用单声道 WAV 头保存。
- 08 综合系统 page_audio.cc 包含录音功能：16000 Hz、16-bit、1 channel，RX LEFT 时隙；保存 /sdcard/music/record_<RTC时间>.wav。
- 音频菜单第3项为录音，拨轮中键确认。录音中单击中键暂停/继续，中键双击或BOOT单击结束（事件8/22）。
- XPowersAXP2101.tpp 的 getBatteryPercent() 在未检测到电池时返回 -1。
- main.cc 的 Restarting now 日志后无 esp_restart()，不能据此认定重启循环。

## 不采纳的 worker 推断
- “未使用 extern 声明必然导致链接失败”不成立；es8311_dev_handle 在该文件仅声明而未引用。
- “双通道右路必为镜像/空、有效幅度必减半”没有实际采样证据；需测量左右槽。
- “动态添加/删除 I2C 设备句柄必然产生 NACK”缺乏证据。

## 版本差异
- 当前官网介绍 PMU 为 TG28，仓库代码命名为 AXP2101 且出厂日志显示初始化成功。不能单凭代码命名确定 PCB 实物芯片型号，不改写未知 PMU 寄存器进行试探。
- 源码存在录音功能不等于当前出厂固件必有同一菜单，需用户界面/设备日志验证。
- 官方录音循环未检查 fwrite 返回值，显示完成仍需文件大小、WAV头和声音内容验收。
