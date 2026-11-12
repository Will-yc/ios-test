// iOS 侧转发：CocoaPods 只认 podspec 里 source_files 声明的文件，
// 而实现放在插件根的 src/ 下与 Android 共用，这里 include 进来编一次即可。
#include "../../src/aec3_bridge.cpp"
