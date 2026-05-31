#pragma once

#include <cstdarg>
#include <cstdio>

enum AbiLogLevel {
    ABI_LL_DEBUG = 0,
    ABI_LL_INFO  = 1,
    ABI_LL_WARN  = 2,
    ABI_LL_ERROR = 3,
    ABI_LL_FATAL = 4,
};

void log_init(bool use_color, bool use_hilog);
void log_write(AbiLogLevel lvl, const char* tag, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

void log_section(const char* title);
void log_banner(const char* title);
void log_result(const char* name, bool ok, const char* detail);
void log_summary(int total, int passed, int failed, double seconds);

#define LOGD(...) log_write(ABI_LL_DEBUG, __FUNCTION__, __VA_ARGS__)
#define LOGI(...) log_write(ABI_LL_INFO,  __FUNCTION__, __VA_ARGS__)
#define LOGW(...) log_write(ABI_LL_WARN,  __FUNCTION__, __VA_ARGS__)
#define LOGE(...) log_write(ABI_LL_ERROR, __FUNCTION__, __VA_ARGS__)
#define LOGF(...) log_write(ABI_LL_FATAL, __FUNCTION__, __VA_ARGS__)