#ifndef AEC3_BRIDGE_H
#define AEC3_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define AEC3_EXPORT __declspec(dllexport)
#else
#define AEC3_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Aec3Bridge Aec3Bridge;

/// 创建实例。[sample_rate] 只支持 16000/32000/48000，[channels] 目前只支持 1。
/// 失败返回 NULL（调用方必须判空并降级为直通）。
AEC3_EXPORT Aec3Bridge *aec3_create(int sample_rate, int channels);

/// 销毁实例，可传 NULL。
AEC3_EXPORT void aec3_destroy(Aec3Bridge *b);

/// 清理内部状态（换文件/续录时调用）。保留已分配的滤波器，避免重收敛开销。
AEC3_EXPORT void aec3_reset(Aec3Bridge *b);

/// 高频旁路开关（TRTC 式全频带，仅 48kHz 生效）。
/// 开启后 0~8kHz 取 AEC 输出、8kHz 以上原样取采集输入 —— 因为 16k opus
/// 参考信号在 8kHz 以上恒为零，那些频带没有回声，AEC3 只会误伤本端人声。
/// 传 0 关闭（行为与旧版完全一致）。
AEC3_EXPORT void aec3_set_high_band_bypass(Aec3Bridge *b, int enable);

/// 运行时切换 NLP（残余抑制）档位，对标 TRTC aec_nlp_level。
/// 0=WebRTC 默认 / 1=温和 / 2=狠（默认）/ 3=极狠。越低档越保守、越高档成品越干净。
/// 换档会重建 APM（自适应滤波器清零、重新收敛 ~1s），构建失败则保持旧档。
AEC3_EXPORT void aec3_set_nlp_level(Aec3Bridge *b, int level);

/// 喂入"正在播放给扬声器"的参考 PCM（int16 交错）。
/// 必须与 aec3_process_capture 使用同一采样率、同一时间轴。
/// 返回累计可用的参考样本数（供调用方观测是否供数不足）。
AEC3_EXPORT int aec3_push_reference(Aec3Bridge *b, const int16_t *pcm, int samples);

/// 处理一帧采集数据。输出的**样本数可能多于或少于**输入的 samples
/// （内部按 10ms 帧对齐，未满帧会留存到下次），调用方必须用返回值推进时间轴。
/// [out] 必须至少能容纳 samples + 512 个 int16。
/// 返回写入 out 的样本数；返回负数表示出错（调用方应退化为直通）。
AEC3_EXPORT int aec3_process_capture(Aec3Bridge *b, const int16_t *in,
                                     int samples, int16_t *out);

/// 最近一次统计：流入/流出的 RMS（dBFS * 10），用于现场判断 AEC 是否在工作。
AEC3_EXPORT void aec3_get_stats(Aec3Bridge *b, int *in_db10, int *out_db10,
                                int *processed_frames, int *ref_starved_frames);

AEC3_EXPORT const char *aec3_build_info(void);

#ifdef __cplusplus
}
#endif

#endif
