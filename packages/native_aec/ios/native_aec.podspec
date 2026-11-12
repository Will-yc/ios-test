#
# WebRTC AEC3 静态库 + 一层 C 桥接，供 Dart FFI 调用。
#
Pod::Spec.new do |s|
  s.name             = 'native_aec'
  s.version          = '0.0.1'
  s.summary          = 'WebRTC AEC3 acoustic echo cancellation for hands-free recording.'
  s.description      = <<-DESC
Wraps webrtc-audio-processing (AEC3 only, mono, 16/32/48kHz) behind a small C API.
                       DESC
  s.homepage         = 'http://example.com'
  # 许可证全文在 ../third_party/webrtc_apm/licenses/ 下（BSD-3 + PATENTS）
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'zyxc' => 'dev@example.com' }

  s.source           = { :path => '.' }
  # 实现放在插件根的 src/ 下与 Android 共用，Classes/ 里只有一个转发文件。
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # WebRTC AudioProcessing（AEC3）静态库。iOS 14+ 是预编译包的下限。
  s.vendored_frameworks = 'Frameworks/WebRTCAudioProcessing.xcframework'
  s.preserve_paths = 'Frameworks/**/*'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # AEC3 的头是 C++20
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    # 头目录：webrtc/* 与 absl/*，以及 webrtc 内部的 "api/audio/..." 相对包含
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../third_party/webrtc_apm/include" "$(PODS_TARGET_SRCROOT)/../third_party/webrtc_apm/include/webrtc" "$(PODS_TARGET_SRCROOT)/../src"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) WEBRTC_LIBRARY_IMPL WEBRTC_POSIX',
  }
  s.swift_version = '5.0'
end
