cmake_minimum_required(VERSION 3.10.2)

project(codec2bridge)

add_library(codec2bridge SHARED codec2_bridge.cpp)

add_library(codec2 SHARED IMPORTED)
set_target_properties(codec2 PROPERTIES
        IMPORTED_LOCATION
        ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libcodec2.so)

find_library(log-lib log)

target_link_libraries(
        codec2bridge
        codec2
        ${log-lib}
)
