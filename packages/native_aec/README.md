# native_aec — WebRTC AEC3 回声消除（FFI 插件）

把 [webrtc-audio-processing](https://github.com/Sqhh99/webrtc-audio-processing)（WebRTC M155 的 AudioProcessing，含 AEC3）
包成一层 C 接口给 Dart 用，用于**外放免提**场景：不戴耳机时，把扬声器放出来的对方声音从麦克风信号里消掉。

## 来源与许可

| 项 | 值 |
|---|---|
| 版本 | `m155.8059.4.0`（对应 WebRTC M155 / Chromium 155） |
| 许可 | BSD-3-Clause + PATENTS（abseil / pffft / rnnoise 已静态链入，可商用闭源） |
| 许可全文 | `third_party/webrtc_apm/licenses/` |
| Android 下限 | API 24（预编译包要求） |
| iOS 下限 | iOS 14（预编译包要求，本工程用 15） |
| 体积 | arm64 so 1.6MB（deflate 后约 646KB）；iOS xcframework 23MB |

## 配置（只开 AEC）

```cpp
config.echo_canceller.enabled = true;
config.echo_canceller.enforce_high_pass_filtering = false;
config.noise_suppression.enabled = false;   // 别动方言语料频响
config.gain_controller1.enabled = false;    // 别动动态
config.gain_controller2.enabled = false;
config.high_pass_filter.enabled = false;    // 浊音基频在 100~300Hz
```

**不要手动 `set_stream_delay_ms()`**：实测显式设 80ms 会让首秒 ERLE 从 26.6dB 掉到 15.5dB，
AEC3 自身的延迟估计更准。

## 用法（Dart）

```dart
final aec = Aec3Processor.tryCreate(sampleRate: 48000);  // null = 该平台没有，降级直通
if (aec != null) {
  // 1. 每帧采集之前，先喂「正在播给扬声器」的 PCM（必须早于 capture）
  aec.pushReference(playbackPcm48k);

  // 2. 处理采集帧。返回长度可能 ≠ 输入长度（内部按 10ms 帧对齐）
  final out = aec.processCapture(micPcm48k);

  // 3. 用返回值推进时间轴，绝不能假设 out.length == in.length
}
```

硬约束：

1. **样本守恒**：总输入 = 总输出，单次调用可能有 ±1 帧的错位。时长、切点一律用返回值推算。
2. **参考信号必须同采样率**（16k/32k/48k，本工程固定 48k）。
3. **只能单 isolate 使用**。

## 为什么不把 AEC 放主 isolate

AEC3 每 10ms 一帧，48k 下每秒 100 次 FFI 调用。放主 isolate 会直接影响 UI。
接入示例（主 App 里）是放在 audio worker isolate 的 `pcm_chunk` 分支，写盘与编码之前。

## Android

- CMake 通过 `IMPORTED` 目标链接 `jniLibs/<abi>/libwebrtc-audio-processing-3.so`
- 预编译库已静态链入 libc++，插件侧也用 AGP 默认的 `c++_static`，不额外打包 `libc++_shared.so`
- **ABI 必须限定在预编译库真实存在的三个**：`arm64-v8a` / `armeabi-v7a` / `x86_64`。
  library 模块会为 `defaultConfig` 里所有 ABI 各跑一遍 CMake，app 侧设 `abiFilters` 挡不住，
  少了这条会在没有 `.so` 的 `x86` 上直接失败。

## iOS

- `podspec` 里 `vendored_frameworks` 指向 `Frameworks/WebRTCAudioProcessing.xcframework`
- `CLANG_CXX_LANGUAGE_STANDARD = c++20`，头路径同时包含 `include` 与 `include/webrtc`
  （WebRTC 内部用 `#include "api/audio/..."` 的相对形式）
- pod 需以 static linkage 使用：`use_frameworks! :linkage => :static`（见 `ios/Podfile`）
- iOS 侧 `DynamicLibrary.process()`，符号静态链入主二进制

## 自测

`lib/demo/aec3_selftest.dart` 用合成信号（远端谐波语音 + 80ms 延迟 + 0.35 耦合 + 3% 非线性 + 本端人声）
跑完整链路，不需要麦克风。App 内有页面，命令行也能跑：

```bash
# 桌面验证（先编出 libnative_aec.so 放到 LD_LIBRARY_PATH）
dart run tool/aec3_offline.dart
```

实测（Android PMA120 arm64 / 桌面 x86_64 / 两者一致）：

| 指标 | 结果 |
|---|---|
| ERLE（纯回声段） | **36.5 dB** |
| 本端独说保真 | **-0.1 dB** |
| 双讲人声保留 | -1.3 dB |
| 样本守恒 | 288000 = 288000 |
| 耗时 | 107ms / 6s 音频（约 56× 实时） |
