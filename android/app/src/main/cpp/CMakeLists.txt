cmake_minimum_required(VERSION 3.4.1)

# 创建共享库，命名为 "native_add"
add_library(native_add SHARED
            native_add.c)

# 设置输出名称（可选）
set_target_properties(native_add PROPERTIES
                      LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")