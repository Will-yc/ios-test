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
#include <vector>

#include <webrtc/api/audio/builtin_audio_processing_builder.h>
#include <webrtc/api/environment/environment_factory.h>
#include <webrtc/api/scoped_refptr.h>
#include <webrtc/modules/audio_processing/include/audio_processing.h>

#define AEC3_MAX_FRAME 480  // 48kHz 下 10ms

namespace {

inline int16_t Clamp16(int v) {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return static_cast<int16_t>(v);
}

}  // namespace

struct Aec3Bridge {
  webrtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  int frame_samples = AEC3_MAX_FRAME;

  std::vector<int16_t> pending;  // 未满一帧的采集残留
  std::deque<int16_t> ref;       // 参考信号队列（按样本计）

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

  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  // 本项目录的是原始人声，不接受 AEC 侧再叠一层高通（会切掉浊音基频）
  config.echo_canceller.enforce_high_pass_filtering = false;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.high_pass_filter.enabled = false;

  auto *b = new (std::nothrow) Aec3Bridge();
  if (b == nullptr) return nullptr;

  b->apm = webrtc::BuiltinAudioProcessingBuilder(config).Build(
      webrtc::CreateEnvironment());
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

void aec3_reset(Aec3Bridge *b) {
  if (b == nullptr) return;
  b->pending.clear();
  b->ref.clear();
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
  return "webrtc-audio-processing m155.8059.4.0 (AEC3 only, mono, 16/32/48k)";
}

}  // extern "C"
