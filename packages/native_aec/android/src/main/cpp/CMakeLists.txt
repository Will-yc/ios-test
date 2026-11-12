cmake_minimum_required(VERSION 3.18)

project(native_aec LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# native_aec/android/src/main/cpp -> native_aec/
set(PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../..")
set(APM_ROOT "${PLUGIN_ROOT}/third_party/webrtc_apm")
set(APM_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libwebrtc-audio-processing-3.so")

# 找不到该 ABI 的预编译库就**不编**桥接层：Dart 侧对 AEC 符号是延迟加载的，
# 拿不到会静默降级为直通，不会让整个插件加载失败。
if(NOT EXISTS "${APM_LIB}")
    message(FATAL_ERROR
            "webrtc_apm 缺少 ${ANDROID_ABI} 的预编译库：${APM_LIB}\n"
            "请补齐 jniLibs/${ANDROID_ABI}/libwebrtc-audio-processing-3.so")
endif()

add_library(webrtc_apm SHARED IMPORTED)
set_target_properties(webrtc_apm PROPERTIES IMPORTED_LOCATION "${APM_LIB}")

add_library(native_aec SHARED "${PLUGIN_ROOT}/src/aec3_bridge.cpp")

target_include_directories(native_aec PRIVATE
        ${APM_ROOT}/include
        ${APM_ROOT}/include/webrtc
        ${PLUGIN_ROOT}/src)

# WEBRTC_LIBRARY_IMPL：消费方必须定义，否则头里的符号可见性语义不对
target_compile_definitions(native_aec PRIVATE
        WEBRTC_LIBRARY_IMPL
        WEBRTC_POSIX)

target_link_libraries(native_aec webrtc_apm log)

# Android 15 的 16KB page size 要求
target_link_options(native_aec PRIVATE "-Wl,-z,max-page-size=16384")
