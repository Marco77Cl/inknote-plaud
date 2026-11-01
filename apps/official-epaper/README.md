# 官方 E-Paper Demo 编译入口

main/ 与 partitions.csv 从 Waveshare commit 9b12d407 原样复制；components 链接到项目的 vendor/waveshare，保留原始驱动。

sdkconfig.defaults 仅设置 ESP32-S3、16 MB Flash、8 MB Octal PSRAM、USB Serial/JTAG 控制台与官方分区表。

此项目是官方显示测试，不是 InkNote 固件。尚未烧录。运行会清屏、显示测试图形和文字，结束后清屏休眠。
