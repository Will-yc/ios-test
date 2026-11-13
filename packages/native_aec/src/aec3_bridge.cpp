// AEC3 桥接层：把 WebRTC AudioProcessing（AEC3）包成 C 接口，供 Dart FFI 调用。
//
// 设计约束（改之前务必想清楚）：
//  1. **样本流守恒**：录音时间轴（duration / cutEnd / 台词 JSON 切点）全部建立在
//     "字节数 ↔ 时长" 的线性关系上。因此本层只允许「延迟 ≤ 一个 10ms 帧」，
//     绝不允许丢样本或重复输出。`aec3_process_capture` 的返回值才是真实写入量，
//     调用方必须用它推进时间轴，不能假设 out == in。
//  2. **参考信号必须早于采集**：APM 要求每处理一帧采集之前，先喂一帧反向流。
//     参考不足时补零（等于"此刻扬声器没响"），并计入 ref_starved。
//  3. **只开 AEC**：NS/AGC/HPF 全部关闭。本项目的成品是方言语料，
//     AGC 会改动态、NS 会改频响、HPF 会切掉 100~300Hz 的浊音基频。
//  4. **不设 stream delay**：实测显式 set_stream_delay_ms(80) 反而让首秒
//     ERLE 从 26.6dB 掉到 15.5dB（AEC3 自身的延迟估计更准），所以不调。

#include "aec3_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <optional>
#include <vector>

#include <webrtc/api/audio/builtin_audio_processing_builder.h>
#include <webrtc/api/audio/echo_canceller3_config.h>
#include <webrtc/api/environment/environment_factory.h>
#include <webrtc/api/scoped_refptr.h>
#include <webrtc/modules/audio_processing/include/audio_processing.h>

#define AEC3_MAX_FRAME 480  // 48kHz 下 10ms

// 分带截止频率（Hz）。参考信号来自 16kHz opus，解码到 48kHz 后 8kHz 以上
// 恒为零 —— 也就是说**回声只存在于 0~8kHz**，8kHz 以上没有任何回声需要消。
constexpr int kSplitHz = 8000;
constexpr double kPi = 3.14159265358979323846;
// 线性相位 FIR：65 抽头、群延迟 32 样本（48kHz 下 0.67ms）。
// 为什么不能用 IIR/biquad：IIR 有相位偏移，`in - LP(in)` 不是互补高通，
// 低带会残留 +1~+5dB 的相位差分量，等于把 AEC 刚消掉的回声又补回来。
constexpr int kFirTaps = 65;
constexpr int kFirDelay = (kFirTaps - 1) / 2;
constexpr int kFirHist = kFirTaps + kFirDelay;

namespace {

inline int16_t Clamp16(int v) {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return static_cast<int16_t>(v);
}

/// 窗函数 sinc 低通（线性相位）。h[n] = 2fc/fs * sinc(2fc*n/fs) * Hamming。
/// 对 in 与 apm 用**同一组系数 + 各自的历史队列**，输出
///   LP(apm)[n] + in[n-D] - LP(in)[n]
/// 低带取 APM 结果、高带取 D 样本前的原始采集；apm==in 时精确等于 in[n-D]
/// （只多 D 个样本的固定延迟，样本数守恒、时间轴长度不变）。
struct SplitFir {
  double h[kFirTaps] = {};

  SplitFir() {
    double sum = 0.0;
    for (int k = 0; k < kFirTaps; ++k) {
      const int n = k - kFirDelay;
      const double v = (n == 0)
                           ? (1.0 / 3.0)
                           : std::sin(kPi * n / 3.0) / (kPi * n);
      const double win =
          0.54 - 0.46 * std::cos(2.0 * kPi * k / (kFirTaps - 1));
      h[k] = v * win;
      sum += h[k];
    }
    for (double &c : h) c /= sum; // DC 增益精确为 1
  }

  static double lowpass(const std::deque<int16_t> &hist, const double *h) {
    double y = 0.0;
    const int n = static_cast<int>(hist.size());
    for (int k = 0; k < kFirTaps; ++k) {
      const int idx = n - 1 - k;
      if (idx < 0) break;
      y += h[k] * hist[idx];
    }
    return y;
  }
};

// TRTC 式 NLP 分级（对标 aec_nlp_level / force_nlp_level）。
//
// AEC3 的残余抑制（NLP）在 suppressor 里，是**频域、逐子带、由自适应滤波器
// 的回声估计驱动**的 —— 对齐天然由 AecState 样本级跟踪，不像手写相关门那样
// 要重新搜延迟、漂移就漏回声。normal_tuning 的 masking 阈值越低，抑制越狠：
//   enr_transparent：ENR（回声/近端）低于它 → 该子带透明（不压）
//   enr_suppress   ：ENR 高于它 → 该子带全压
// 调低这两个值 = 更早、更狠地压残余（成品优先）。
// nearend_tuning / dominant_nearend_detection 一律保持 WebRTC 默认：双讲时
// AEC3 自动切到温和档（LF 阈值 1.09/1.1）保护本端人声 —— 这正是相关门做不到
// 的「分级」，也是 TRTC「纯回声硬压、双讲软压」的同构实现。
webrtc::EchoCanceller3Config MakeAec3Config(int nlp_level) {
  using MT = webrtc::EchoCanceller3Config::Suppressor::MaskingThresholds;
  using Tuning = webrtc::EchoCanceller3Config::Suppressor::Tuning;
  webrtc::EchoCanceller3Config c;
  switch (nlp_level) {
    case 0:  // WebRTC 默认（A/B 基线）
      c.suppressor.normal_tuning =
          Tuning(MT(.3f, .4f, .3f), MT(.07f, .1f, .3f), 2.0f, 0.25f);
      break;
    case 1:  // 温和
      c.suppressor.normal_tuning =
          Tuning(MT(.2f, .3f, .25f), MT(.05f, .08f, .25f), 2.0f, 0.25f);
      break;
    case 3:  // 极狠（成品最干净，双讲外可能吃本端齿音）
      c.suppressor.normal_tuning =
          Tuning(MT(.1f, .18f, .15f), MT(.03f, .05f, .15f), 2.0f, 0.25f);
      break;
    case 2:  // 默认：TRTC 式狠档
    default:
      c.suppressor.normal_tuning =
          Tuning(MT(.15f, .25f, .2f), MT(.04f, .07f, .2f), 2.0f, 0.25f);
      break;
  }
  return c;
}

// 只开 AEC（NS/AGC/HPF 全关，成品要原始频响与真实噪底），注入分级 suppressor。
webrtc::scoped_refptr<webrtc::AudioProcessing> BuildApm(int sample_rate,
                                                        int channels,
                                                        int nlp_level) {
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  // 本项目录的是原始人声，不接受 AEC 侧再叠一层高通（会切掉浊音基频）
  config.echo_canceller.enforce_high_pass_filtering = false;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.high_pass_filter.enabled = false;
  return webrtc::BuiltinAudioProcessingBuilder(config)
      .SetEchoCancellerConfig(MakeAec3Config(nlp_level), std::nullopt)
      .Build(webrtc::CreateEnvironment());
}

}  // namespace

struct Aec3Bridge {
  webrtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  int frame_samples = AEC3_MAX_FRAME;
  // 重建 APM（换 NLP 档）时需要原始创建参数
  int sample_rate = 48000;
  int channels = 1;
  int nlp_level = 2;  // 默认 TRTC 式狠档

  std::vector<int16_t> pending;  // 未满一帧的采集残留
  std::deque<int16_t> ref;       // 参考信号队列（按样本计）

  // 高频旁路（TRTC 式全频带）：APM 的 48kHz 三子带处理会用低带增益去压
  // 8kHz 以上的高子带，但那些频带里根本没有回声，只会把本端人声的齿音、
  // 空气感削掉 30~40dB。开启后 8kHz 以上原样取自采集。
  bool high_band_bypass = false;
  SplitFir fir;                  // 系数只构造一次（每次 create）
  std::deque<int16_t> raw_hist;  // 采集历史（跨 10ms 帧保持）
  std::deque<int16_t> apm_hist;  // APM 输出历史

  // 统计（指数滑动，反映"最近"而不是全程平均）
  double rms_in = 0.0;
  double rms_out = 0.0;
  int processed_frames = 0;
  int starved_frames = 0;
};

extern "C" {

Aec3Bridge *aec3_create(int sample_rate, int channels) {
  if (channels != 1) return nullptr;
  if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) {
    return nullptr;
  }

  auto *b = new (std::nothrow) Aec3Bridge();
  if (b == nullptr) return nullptr;

  b->sample_rate = sample_rate;
  b->channels = channels;
  b->apm = BuildApm(sample_rate, channels, b->nlp_level);
  if (b->apm == nullptr) {
    delete b;
    return nullptr;
  }

  b->stream = webrtc::StreamConfig(sample_rate, channels);
  b->frame_samples = sample_rate / 100;  // 10ms
  b->pending.reserve(b->frame_samples * 2);
  return b;
}

void aec3_destroy(Aec3Bridge *b) { delete b; }

// 运行时换 NLP 档（TRTC aec_nlp_level 语义）。EchoCanceller3Config 只能在
// Build 时注入，没有运行时 ApplyConfig 通路，所以换档 = 重建 APM。重建会清掉
// 自适应滤波器，必须连同所有跨帧状态一起复位、重新收敛（~1s）。调用方应在
// 换档后容忍这段收敛期。构建失败则保持旧档，绝不让句柄变空。
void aec3_set_nlp_level(Aec3Bridge *b, int level) {
  if (b == nullptr) return;
  if (level < 0) level = 0;
  if (level > 3) level = 3;
  if (level == b->nlp_level && b->apm != nullptr) return;
  auto apm = BuildApm(b->sample_rate, b->channels, level);
  if (apm == nullptr) return;
  b->apm = apm;
  b->nlp_level = level;
  b->pending.clear();
  b->ref.clear();
  b->raw_hist.clear();
  b->apm_hist.clear();
  b->rms_in = 0.0;
  b->rms_out = 0.0;
  b->processed_frames = 0;
  b->starved_frames = 0;
}

void aec3_set_high_band_bypass(Aec3Bridge *b, int enable) {
  if (b == nullptr) return;
  // 仅在 48kHz 下有意义：16k/32k 输入本来就没有可保留的高频带
  b->high_band_bypass =
      (enable != 0 && b->stream.sample_rate_hz() == 48000);
  b->raw_hist.clear();
  b->apm_hist.clear();
}

void aec3_reset(Aec3Bridge *b) {
  if (b == nullptr) return;
  b->pending.clear();
  b->ref.clear();
  b->raw_hist.clear();
  b->apm_hist.clear();
  b->rms_in = 0.0;
  b->rms_out = 0.0;
  b->processed_frames = 0;
  b->starved_frames = 0;
}

int aec3_push_reference(Aec3Bridge *b, const int16_t *pcm, int samples) {
  if (b == nullptr) return 0;
  if (pcm != nullptr && samples > 0) {
    // 上限 5 秒：防止网络抖动批量到达时无限膨胀
    const size_t cap = static_cast<size_t>(b->stream.sample_rate_hz()) * 5;
    b->ref.insert(b->ref.end(), pcm, pcm + samples);
    while (b->ref.size() > cap) b->ref.pop_front();
  }
  return static_cast<int>(b->ref.size());
}

int aec3_process_capture(Aec3Bridge *b, const int16_t *in, int samples,
                         int16_t *out) {
  if (b == nullptr || out == nullptr) return -1;
  if (in == nullptr || samples <= 0) return 0;

  const int fs = b->frame_samples;
  b->pending.insert(b->pending.end(), in, in + samples);

  int written = 0;
  size_t pos = 0;
  int16_t ref_frame[AEC3_MAX_FRAME];
  int16_t cap_frame[AEC3_MAX_FRAME];

  while (b->pending.size() - pos >= static_cast<size_t>(fs)) {
    // ---- 参考帧：不足则补零（此刻扬声器没有新内容）----
    if (b->ref.size() >= static_cast<size_t>(fs)) {
      for (int i = 0; i < fs; ++i) {
        ref_frame[i] = b->ref.front();
        b->ref.pop_front();
      }
    } else {
      std::memset(ref_frame, 0, sizeof(int16_t) * fs);
      b->starved_frames++;
    }

    std::memcpy(cap_frame, b->pending.data() + pos, sizeof(int16_t) * fs);

    // APM 要求：先反向流，再采集流
    b->apm->ProcessReverseStream(ref_frame, b->stream, b->stream, ref_frame);
    const int err = b->apm->ProcessStream(cap_frame, b->stream, b->stream,
                                          cap_frame);
    if (err != 0) {
      // 出错就退回原始数据，绝不能让这一帧变成静音
      std::memcpy(cap_frame, b->pending.data() + pos, sizeof(int16_t) * fs);
    }

    // ---- 高频旁路：低带用 AEC 结果，高带用原始采集 ----
    // 参考信号是 16k opus（8kHz 带宽），8kHz 以上没有回声可消；AEC3 在 48kHz
    // 下的三子带抑制却会把低带增益套到高子带，把本端人声的 8~20kHz 一并压掉。
    // 线性相位 FIR 分带：LP(apm)[n] + in[n-D] - LP(in)[n]，D=32 样本。
    // 只有 0.67ms 固定延迟，样本数守恒，0~8kHz 的消回声结果逐点保留。
    if (b->high_band_bypass) {
      for (int i = 0; i < fs; ++i) {
        const int16_t raw = b->pending[pos + i];
        const int16_t processed = cap_frame[i];
        b->raw_hist.push_back(raw);
        b->apm_hist.push_back(processed);
        if (b->raw_hist.size() > static_cast<size_t>(kFirHist)) {
          b->raw_hist.pop_front();
        }
        if (b->apm_hist.size() > static_cast<size_t>(kFirHist)) {
          b->apm_hist.pop_front();
        }

        const double lp_apm = SplitFir::lowpass(b->apm_hist, b->fir.h);
        const double lp_raw = SplitFir::lowpass(b->raw_hist, b->fir.h);
        const int di = static_cast<int>(b->raw_hist.size()) - 1 - kFirDelay;
        const double delayed_raw = di >= 0 ? b->raw_hist[di] : 0.0;
        const double mixed = lp_apm + delayed_raw - lp_raw;
        cap_frame[i] = Clamp16(static_cast<int>(std::lround(mixed)));
      }
    }

    // ---- 统计 ----
    double sin_sq = 0.0, sout_sq = 0.0;
    for (int i = 0; i < fs; ++i) {
      const double a = b->pending[pos + i];
      const double c = cap_frame[i];
      sin_sq += a * a;
      sout_sq += c * c;
    }
    const double kin = std::sqrt(sin_sq / fs);
    const double kout = std::sqrt(sout_sq / fs);
    b->rms_in = b->rms_in * 0.95 + kin * 0.05;
    b->rms_out = b->rms_out * 0.95 + kout * 0.05;

    std::memcpy(out + written, cap_frame, sizeof(int16_t) * fs);
    written += fs;
    pos += fs;
    b->processed_frames++;
  }

  if (pos > 0) b->pending.erase(b->pending.begin(), b->pending.begin() + pos);
  return written;
}

void aec3_get_stats(Aec3Bridge *b, int *in_db10, int *out_db10,
                    int *processed_frames, int *ref_starved_frames) {
  if (b == nullptr) return;
  const double eps = 1e-9;
  if (in_db10 != nullptr) {
    *in_db10 = static_cast<int>(
        std::lround(200.0 * std::log10(std::max(b->rms_in, eps) / 32768.0)));
  }
  if (out_db10 != nullptr) {
    *out_db10 = static_cast<int>(
        std::lround(200.0 * std::log10(std::max(b->rms_out, eps) / 32768.0)));
  }
  if (processed_frames != nullptr) *processed_frames = b->processed_frames;
  if (ref_starved_frames != nullptr) *ref_starved_frames = b->starved_frames;
}

const char *aec3_build_info(void) {
  return "webrtc-audio-processing m155.8059.4.0 (AEC3 only, mono, 16/32/48k, fullband-bypass, nlp-graded)";
}

}  // extern "C"
