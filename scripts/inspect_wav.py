#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WAV 验收工具（仅使用 Python 标准库）。

验收项：
  1. PCM 未压缩（comptype == NONE）
  2. 采样率 16000 Hz
  3. 16 bit
  4. 单声道
  5. 帧数非零
  6. 实际可读取的数据字节数 == 头部声明的字节数

输出：单个 JSON 对象到 stdout。

退出码：
  0  全部通过
  1  文件不存在 / 无法打开 / 不是合法 WAV
  2  参数不符合要求（压缩方式、采样率、位深、声道数）
  3  可读取的 data chunk 长度与头部声明不一致
  4  帧数为零（空数据）

关于静音：本工具只做“报告”，不做“判断”。检测到静音只会写入
silence_suspected / warnings，并且 mic_verified 恒为 false——
没有真实录音链路就无法证明麦克风工作正常，工具不冒充这个结论。
"""

import argparse
import json
import math
import os
import struct
import sys
import wave

# 每次读取的字节数上限，避免整段音频载入内存。
CHUNK_BYTES = 1 << 16

# 目标参数
TARGET_RATE = 16000
TARGET_CHANNELS = 1
TARGET_SAMPWIDTH = 2  # 字节，即 16 bit

# PCM 16bit 小端样本
SAMPLE_BYTES = 2
SAMPLE_FMT = "<h"
FULL_SCALE = 32768.0  # int16 满量程

# 退出码
EXIT_OK = 0
EXIT_UNREADABLE = 1
EXIT_PARAM = 2
EXIT_LENGTH = 3
EXIT_EMPTY = 4

# 退出码优先级：越靠前越先返回
EXIT_PRIORITY = (EXIT_UNREADABLE, EXIT_PARAM, EXIT_LENGTH, EXIT_EMPTY)

# RMS 以整数 PCM 样本为单位，低于 1 LSB 视为近似静音
NEAR_SILENCE_RMS = 1.0


def _empty_report(path):
    """失败路径也要给出结构完整的 JSON。"""
    try:
        file_size = os.path.getsize(path)
    except OSError:
        file_size = None
    return {
        "file": path,
        "file_size_bytes": file_size,
        "format": {
            "compression": None,
            "channels": None,
            "sample_rate_hz": None,
            "sample_width_bytes": None,
            "bits_per_sample": None,
            "frames_declared": None,
            "data_bytes_declared": None,
        },
        "read": {
            "frames_read": None,
            "data_bytes_read": None,
            "leftover_bytes": None,
            "read_error": None,
        },
        "duration_seconds": None,
        "duration_declared_seconds": None,
        "sample_count": None,
        "zero_sample_count": None,
        "zero_sample_ratio": None,
        "peak": None,
        "peak_normalized": None,
        "rms": None,
        "rms_dbfs": None,
        "silence_suspected": None,
        "near_silence_suspected": None,
        "mic_verified": False,
        "checks": {
            "pcm_uncompressed": None,
            "sample_rate_16000": None,
            "bits_16": None,
            "mono": None,
            "non_zero_frames": None,
            "data_length_matches_header": None,
        },
        "errors": [],
        "warnings": [],
        "ok": False,
    }


def _read_samples(wf, frame_size, collect_stats):
    """分块读取全部帧。

    返回 (bytes_read, sample_count, zero_count, peak, sumsq, leftover, read_error)。
    只有 sampwidth == 2 时才统计样本，否则只统计字节数。
    """
    bytes_read = 0
    sample_count = 0
    zero_count = 0
    peak = 0
    sumsq = 0
    carry = b""
    read_error = None

    frames_per_chunk = max(1, CHUNK_BYTES // frame_size) if frame_size else 1

    while True:
        try:
            block = wf.readframes(frames_per_chunk)
        except EOFError as exc:
            # 文件被截断，3.12+ 会抛 EOFError
            read_error = "EOFError: %s" % (exc,)
            break
        except wave.Error as exc:
            read_error = "wave.Error: %s" % (exc,)
            break

        if not block:
            break

        bytes_read += len(block)

        if collect_stats:
            data = carry + block
            usable = len(data) - (len(data) % SAMPLE_BYTES)
            if usable:
                for (sample,) in struct.iter_unpack(SAMPLE_FMT, data[:usable]):
                    if sample < 0:
                        magnitude = -sample
                    else:
                        magnitude = sample
                    if magnitude > peak:
                        peak = magnitude
                    if sample == 0:
                        zero_count += 1
                    sumsq += sample * sample
                sample_count += usable // SAMPLE_BYTES
            carry = data[usable:]

    leftover = bytes_read % frame_size if frame_size else 0
    return bytes_read, sample_count, zero_count, peak, sumsq, leftover, read_error


def inspect(path):
    """返回 (report, exit_code)。"""
    report = _empty_report(path)
    codes = set()

    try:
        wf = wave.open(path, "rb")
    except FileNotFoundError:
        report["errors"].append("file not found")
        return report, EXIT_UNREADABLE
    except IsADirectoryError:
        report["errors"].append("path is a directory, not a wav file")
        return report, EXIT_UNREADABLE
    except PermissionError:
        report["errors"].append("permission denied")
        return report, EXIT_UNREADABLE
    except (wave.Error, EOFError) as exc:
        report["errors"].append("not a readable wav file: %s" % (exc,))
        return report, EXIT_UNREADABLE
    except OSError as exc:
        report["errors"].append("cannot open file: %s" % (exc,))
        return report, EXIT_UNREADABLE

    with wf:
        try:
            compression = wf.getcomptype()
            channels = wf.getnchannels()
            rate = wf.getframerate()
            sampwidth = wf.getsampwidth()
            frames_declared = wf.getnframes()
        except (wave.Error, EOFError) as exc:
            report["errors"].append("cannot read wav header: %s" % (exc,))
            return report, EXIT_UNREADABLE

        frame_size = channels * sampwidth
        data_bytes_declared = frames_declared * frame_size

        report["format"].update(
            {
                "compression": compression,
                "channels": channels,
                "sample_rate_hz": rate,
                "sample_width_bytes": sampwidth,
                "bits_per_sample": sampwidth * 8,
                "frames_declared": frames_declared,
                "data_bytes_declared": data_bytes_declared,
            }
        )

        (
            bytes_read,
            sample_count,
            zero_count,
            peak,
            sumsq,
            leftover,
            read_error,
        ) = _read_samples(wf, frame_size, collect_stats=(sampwidth == SAMPLE_BYTES))

    frames_read = bytes_read // frame_size if frame_size else 0
    report["read"].update(
        {
            "frames_read": frames_read,
            "data_bytes_read": bytes_read,
            "leftover_bytes": leftover,
            "read_error": read_error,
        }
    )

    if read_error:
        codes.add(EXIT_LENGTH)
        report["errors"].append("data read stopped early: %s" % read_error)

    # ---- 参数校验 ----
    pcm_ok = compression == "NONE"
    rate_ok = rate == TARGET_RATE
    bits_ok = sampwidth == TARGET_SAMPWIDTH
    mono_ok = channels == TARGET_CHANNELS

    if not pcm_ok:
        codes.add(EXIT_PARAM)
        report["errors"].append(
            "compression is %r, expected uncompressed PCM ('NONE')" % (compression,)
        )
    if not rate_ok:
        codes.add(EXIT_PARAM)
        report["errors"].append(
            "sample rate is %s Hz, expected %d Hz" % (rate, TARGET_RATE)
        )
    if not bits_ok:
        codes.add(EXIT_PARAM)
        report["errors"].append(
            "sample width is %s bit, expected %d bit"
            % (sampwidth * 8, TARGET_SAMPWIDTH * 8)
        )
    if not mono_ok:
        codes.add(EXIT_PARAM)
        report["errors"].append(
            "channel count is %s, expected %d (mono)" % (channels, TARGET_CHANNELS)
        )

    # ---- 长度校验：实际可读长度 == 头部声明 ----
    length_ok = bytes_read == data_bytes_declared
    if not length_ok:
        codes.add(EXIT_LENGTH)
        report["errors"].append(
            "data length mismatch: header declares %d bytes, read %d bytes"
            % (data_bytes_declared, bytes_read)
        )
    if leftover:
        codes.add(EXIT_LENGTH)
        report["errors"].append(
            "%d trailing byte(s) do not form a complete frame" % leftover
        )
    if frame_size == 0:
        codes.add(EXIT_PARAM)
        report["errors"].append("frame size is zero (invalid channels/sample width)")

    # ---- 非零帧 ----
    frames_non_zero = frames_declared > 0 and frames_read > 0
    if not frames_non_zero:
        codes.add(EXIT_EMPTY)
        report["errors"].append("no audio frames (empty data chunk)")

    # ---- 统计 ----
    if frames_declared and rate:
        report["duration_declared_seconds"] = frames_declared / float(rate)
    if frames_read and rate:
        report["duration_seconds"] = frames_read / float(rate)

    if sampwidth == SAMPLE_BYTES:
        report["sample_count"] = sample_count
        report["zero_sample_count"] = zero_count
        report["peak"] = peak
        report["peak_normalized"] = peak / FULL_SCALE

        if sample_count:
            report["zero_sample_ratio"] = zero_count / float(sample_count)
            rms = math.sqrt(sumsq / float(sample_count))
        else:
            report["zero_sample_ratio"] = None
            rms = None

        report["rms"] = rms
        if rms is not None and rms > 0.0:
            report["rms_dbfs"] = 20.0 * math.log10(rms / FULL_SCALE)
        else:
            report["rms_dbfs"] = None

        # ---- 静音：只报告，不下结论 ----
        digital_silence = sample_count > 0 and peak == 0
        near_silence = rms is not None and rms < NEAR_SILENCE_RMS
        report["silence_suspected"] = digital_silence
        report["near_silence_suspected"] = near_silence

        if digital_silence:
            report["warnings"].append(
                "all %d samples are zero (digital silence); "
                "this does NOT prove the microphone works or fails"
                % sample_count
            )
        elif near_silence:
            report["warnings"].append(
                "near silence: rms=%.4f (< %.1f LSB); "
                "treat as a signal-quality note only, not a mic verdict"
                % (rms, NEAR_SILENCE_RMS)
            )
        if sample_count and zero_count and not digital_silence:
            report["warnings"].append(
                "%d/%d samples (%.2f%%) are exactly zero"
                % (zero_count, sample_count, 100.0 * zero_count / sample_count)
            )
    else:
        report["warnings"].append(
            "sample statistics skipped: not 16-bit PCM (sample width %s bit)"
            % (sampwidth * 8,)
        )

    report["mic_verified"] = False

    report["checks"].update(
        {
            "pcm_uncompressed": pcm_ok,
            "sample_rate_16000": rate_ok,
            "bits_16": bits_ok,
            "mono": mono_ok,
            "non_zero_frames": frames_non_zero,
            "data_length_matches_header": length_ok and leftover == 0 and not read_error,
        }
    )

    report["ok"] = not codes

    for code in EXIT_PRIORITY:
        if code in codes:
            return report, code
    return report, EXIT_OK


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="inspect_wav.py",
        description=(
            "验收 WAV 文件：PCM 未压缩 / 16000Hz / 16bit / mono / 非零帧 / "
            "实际数据长度等于头部声明。输出 JSON，失败返回非零退出码。"
        ),
    )
    parser.add_argument("wav", help="待检查的 WAV 文件路径")
    parser.add_argument(
        "--compact",
        action="store_true",
        help="输出单行 JSON（默认缩进美化）",
    )
    args = parser.parse_args(argv)

    report, code = inspect(args.wav)
    if args.compact:
        sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
        )
    sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(main())
