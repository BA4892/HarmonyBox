cmake_minimum_required(VERSION 3.10)
project(abitest C CXX)

set(CMAKE_C_STANDARD   11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

add_compile_options(
    -Wall -Wextra
    -Wno-unused-parameter
    -Wno-unused-variable
    -fexceptions
)

option(USE_HILOG "Enable hilog output (requires OHOS NDK)" ON)

set(SRCS
    src/main.cpp
    src/log_util.cpp
    src/test_runner.cpp
    src/sysinfo_test.cpp
    src/proc_test.cpp
    src/dlopen_test.cpp
    src/signal_test.cpp
    src/thread_test.cpp
    src/jit_test.cpp
    src/syscall_test.cpp
    src/sigsys_test.cpp
)

add_executable(abitest ${SRCS})
target_include_directories(abitest PRIVATE src)

# 静态链接 libstdc++ 让二进制更便携（在没有 libc++.so 的极端场景仍可跑）
target_link_options(abitest PRIVATE
    -static-libstdc++
    -static-libgcc
)

target_link_libraries(abitest PRIVATE pthread dl)

if(USE_HILOG)
    find_library(HILOG_LIB hilog_ndk.z)
    if(HILOG_LIB)
        message(STATUS "hilog: ${HILOG_LIB}")
        target_compile_definitions(abitest PRIVATE HAVE_HILOG=1)
        target_link_libraries(abitest PRIVATE ${HILOG_LIB})
    else()
        message(STATUS "hilog NOT found, building stdout-only")
    endif()
endif()

install(TARGETS abitest RUNTIME DESTINATION bin)