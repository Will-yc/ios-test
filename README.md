# my_flutter_app — 音频验证工程

用来验证音频链路里那些「换个环境就跑不起来」的部分。目前承载两块：

1. **opus / PcmSound 实时播放**（`lib/demo/test_opus.dart`）
2. **WebRTC AEC3 外放回声消除**（`packages/native_aec` + `lib/demo/aec3_test_page.dart`）

---

## AEC3 验证

### 它是干什么的

不戴耳机做双人对录时，扬声器放出来的对方声音会被麦克风再收一遍，混进录音成品里。
AEC3 用「正在播放的 PCM」当参考信号，把这部分回声从采集信号里减掉，只留本端人声。

### 三条验证路径

| 路径 | 验证什么 | 怎么跑 |
|---|---|---|
| **桌面 CLI** | Dart 信号构造 / FFI 通路 / 统计口径 | `LD_LIBRARY_PATH=<含 libnative_aec.so 的目录> dart run tool/aec3_offline.dart` |
| **Android 真机** | NDK 编译 / so 打包 / 运行时符号解析 / 真实 SoC 性能 | `flutter build apk --debug`，装上后点「AEC3 回声消除自测」 |
| **iOS CI** | pod install / xcframework 链接 / C++20 编译 / 符号入库 | push 后自动跑 `.github/workflows/aec3-build-check.yml` |

自测用的是**合成信号**（远端谐波语音 + 80ms 延迟 + 0.35 耦合 + 3% 非线性 + 本端人声），
不需要麦克风、不需要两台手机，所以 Android / iOS / 桌面拿到的是同一道题，结果可直接对比。

### 已验证的结果

| 指标 | Android（PMA120 arm64） | 桌面（x86_64） |
|---|---|---|
| 库加载 | ✅ `m155.8059.4.0` | ✅ 同 |
| ERLE（纯回声段） | **36.5 dB** | 36.5 dB |
| 本端独说保真 | **-0.1 dB** | -0.1 dB |
| 双讲人声保留 | -1.3 dB | -1.3 dB |
| 样本守恒 | 288000 = 288000 | 相同 |
| 6 秒音频耗时 | 107 ms（≈56× 实时） | 202 ms |

iOS 的编译结果看 Actions 里 `AEC3 build check` 的 `iOS (no codesign)` job。

### 合格线

- **ERLE ≥ 25dB** 且 **样本严格守恒** → 通过
- 两端都低于 20dB 才需要排查（先怀疑 xcframework 没链进去 / 头路径不对）
- 双讲 -3~-6dB 是 AEC 的 NLP 正常行为，不是 bug

---

## CI

### `aec3-build-check.yml`（免签名，日常用）

push 到 `main` 且改到 `lib/**`、`packages/native_aec/**`、`pubspec.yaml`、`ios/**`、`android/**` 时自动跑：

- **Android**：`flutter build apk --debug --target-platform android-arm64`，
  然后断言 APK 里同时存在 `libnative_aec.so` 与 `libwebrtc-audio-processing-3.so`
- **iOS**：`pod install` + `flutter build ios --debug --no-codesign`，
  然后 `nm` 断言 `aec3_create` / `aec3_process_capture` 等符号确实进了 Runner 二进制

不需要任何 secrets。

### `ios-release.yml`（出 IPA，手动触发）

只在 Actions 页面手动 `Run workflow` 时跑，需要签名证书。配置：

```
/settings/secrets/actions

base64 -i distribution.p12 | tr -d '\n\r' > p12_base64.txt
base64 -i zyxctest.mobileprovision | tr -d '\n\r' > profile_base64.txt
```

需要的 secrets：`IOS_P12_BASE64`、`IOS_P12_PASSWORD`、`IOS_PROVISION_PROFILE`。

---

## 目录

```
packages/native_aec/           AEC3 FFI 插件（库、C 桥接、podspec、CMake）
  third_party/webrtc_apm/      预编译库 + 头 + 许可
  src/aec3_bridge.{h,cpp}      C 接口（样本守恒 / 只开 AEC）
lib/demo/aec3_selftest.dart    自测逻辑（纯 Dart，App 与 CLI 共用）
lib/demo/aec3_test_page.dart   自测页 UI
tool/aec3_offline.dart         命令行入口
```

## 已知限制

- **预编译包没有 `x86`**，只有 `arm64-v8a` / `armeabi-v7a` / `x86_64`，所以 ABI 必须限定在这三个
- 自测是合成信号，**真机非线性回声**（扬声器大音量失真）比合成信号更狠，ERLE 会低一些；
  要拿真机数字，需要把真机的 mic 与播放 PCM 分别落盘后再跑
- 双讲时本端人声会被压 3~6dB，这是 AEC3 NLP 的固有代价（独说时无损）
