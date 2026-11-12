# third_party/webrtc_apm — WebRTC AudioProcessing（AEC3）

## 这是什么

WebRTC 的音频前端（Audio Processing Module），本项目只用到它的 **AEC3 回声消除**，
用于「外放免提」场景：扬声器放出来的对方声音会被本地麦克风再收一遍，
不消掉就会写进 `.pcm` 成品。

## 来源与版本

| 项 | 值 |
|---|---|
| 上游 | PulseAudio / PipeWire 维护的 `webrtc-audio-processing`（freedesktop） |
| 二进制来源 | `https://github.com/Sqhh99/webrtc-audio-processing`（镜像 + 双平台预编译） |
| 版本 | `m155.8059.4.0`（WebRTC M155 / Chromium 155.0.8059.39，2026-10-11） |
| Android 包 sha256 | `0d9d3d9d801e2cfcd3b73a7296352037ac6c0b41a2632bee675c0162913e253b` |

## 目录

```
include/webrtc/     APM 公开头（api/ modules/ rtc_base/ system_wrappers/）
include/absl/       abseil 头（只保留被引用到的 7 个子目录）
android/<abi>/      预编译 .so（arm64-v8a / armeabi-v7a / x86_64，API 24+）
                    ↑ 放在插件 android/src/main/jniLibs/ 下由 AGP 打包
ios/                见 native_add/ios/Frameworks/WebRTCAudioProcessing.xcframework
licenses/           BSD-3 + PATENTS + abseil(Apache-2.0) + pffft + rnnoise
```

> 头文件是裁剪过的：只保留编译 `aec3_bridge.cpp` 必需的依赖闭包（2.6MB）。
> 如果升级版本后报缺头，从新包的 `include/` 里把对应 `absl/<目录>` 补回来即可。

## 为什么不用 AECM

M155 已**彻底移除** AECM 路径（`Config::EchoCanceller::mobile_mode` 字段不存在了），
只剩 AEC3。所以不存在"轻量模式"可选，48k 下的算力必须实测（预计单核 5~15%）。

## 使用方式

C 接口在 `native_add/src/aec3_bridge.h`，Dart 封装是 `Aec3Processor`。
硬性约束（改之前务必看 `aec3_bridge.cpp` 顶部注释）：

1. **每 10ms 帧必须先 `ProcessReverseStream`（参考）再 `ProcessStream`（采集）**。
2. 只开 AEC，**关掉** NS / AGC1 / AGC2 / HPF —— 成品是方言语音语料，
   这些会改动态和频响，HPF 还会切掉 100~300Hz 的浊音基频。
3. **不要手动 `set_stream_delay_ms`**：实测显式设 80ms 会让首秒 ERLE
   从 26.6dB 掉到 15.5dB，AEC3 自己的延迟估计更准。
4. 参考信号与采集信号**必须同采样率**。所以播放链路输出 48k
   （`OpusDecoder(sampleRate: 48000)`），与采集的 48k 天然对齐，不做任何重采样。

## 实测（合成信号：110Hz 谐波语音 + 80ms 声学延迟 + 0.35 耦合 + 3% 三次非线性）

| 指标 | 结果 |
|---|---|
| ERLE 稳态 | 30.6 dB |
| 收敛时间 | < 1 秒 |
| 本端独说损伤 | 0.0 dB |
| 双讲时本地人声 | 被压 -4.6 dB（**真实代价**，AEC3 的 NLP 行为） |
| 8kHz 以上高频保留 | -0.5 dB（48k 全频带成立） |
| 参考领先 0~500ms | ERLE 恒为 28.7dB（不敏感，无需精确控制播放缓冲） |
| 样本守恒 | 任意分块（480/960/1000/1920）总字节严格相等 |

## 升级步骤

```bash
# 1. 下载新版本的 android.tar.gz / WebRTCAudioProcessing.xcframework.zip
# 2. 替换 android/src/main/jniLibs/<abi>/*.so 与 ios/Frameworks/*.xcframework
# 3. 用新包 include/ 替换 third_party/webrtc_apm/include/（保留 absl 裁剪）
# 4. 桌面验证（不用上手机）：
g++ -std=c++20 -O2 test_bridge.cpp src/aec3_bridge.cpp \
    -Isrc -Ithird_party/webrtc_apm/include \
    -Ithird_party/webrtc_apm/include/webrtc \
    -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX \
    -L<linux版解包目录>/lib -lwebrtc-audio-processing-3 -lpthread -lrt
```

## 许可证

WebRTC 代码为 **BSD 3-clause**（含 `PATENTS` 额外专利授权），abseil 为 Apache-2.0，
pffft 为 FFTPACK、rnnoise 为 BSD。**允许商业闭源使用**，只需在应用的
「开源许可」页保留这些声明。详见 `licenses/`。
