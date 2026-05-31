#!/usr/bin/env bash
# Box64 source patches for HarmonyOS / OHOS musl.
#
# 用法:
#   被 build_box64_ohos_clean.sh 调用,需 BOX64 环境变量指向源码目录.
#   也可以独立运行:  BOX64=~/HarmonyBox/box64 bash patches.sh
#
# 设计:
#   - 每条 patch 一个函数, 自带原因说明
#   - 通过源码内标记注释判断是否已打过, 幂等
#   - 任一条失败立即退出 (set -e), 由 build.sh 统一处理

set -e

: "${BOX64:?BOX64 环境变量未设置 (应指向 box64 源码目录)}"

if [ ! -d "$BOX64" ]; then
    echo "ERROR: BOX64 目录不存在: $BOX64"
    exit 1
fi

ROOT=~/HarmonyBox
THIRD_PARTY=$ROOT/thirdparty
mkdir -p "$THIRD_PARTY"

# ---------- 工具 ----------

_patch_header() {
    # $1 编号  $2 文件  $3 一句话描述
    printf '    [#%-2s] %-40s  %s\n' "$1" "$2" "$3"
}

_already() {
    # $1 文件  $2 标记
    [ -f "$1" ] && grep -q "$2" "$1"
}

_clone_shallow() {
    # $1 url  $2 dest
    local url="$1" dest="$2"
    if [ -d "$dest/.git" ]; then
        return 0
    fi
    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        # 不是 git 仓库但又非空, 不动
        return 0
    fi
    rm -rf "$dest"
    git clone --depth=1 "$url" "$dest"
}

# ================================================================
# Patch 01 — src/os/os_linux.c: musl mallopt 兼容
# ================================================================
# 报错:
#   error: use of undeclared identifier 'M_ARENA_TEST'
#   error: use of undeclared identifier 'M_ARENA_MAX'
#   error: use of undeclared identifier 'M_MMAP_THRESHOLD'
#
# 原因:
#   M_ARENA_* 与 M_MMAP_THRESHOLD 是 glibc ptmalloc 的私有调参常量,
#   musl 的 malloc 不识别也不暴露这些符号.
#
# 修法:
#   用 #ifdef 包裹这三行 mallopt 调用; 未定义就跳过.
#   musl 下这些调参没意义, 跳过对 box64 功能无影响.
patch_01_mallopt() {
    local f="$BOX64/src/os/os_linux.c"
    local mark='OHOS_PATCH_MALLOPT'

    [ -f "$f" ] || { _patch_header 01 "(skip) os_linux.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 01 "src/os/os_linux.c" "mallopt — already patched"
        return 0
    fi
    _patch_header 01 "src/os/os_linux.c" "wrap M_ARENA_*/M_MMAP_THRESHOLD with #ifdef"

    sed -i "1i\\
/* $mark */" "$f"

    sed -i \
        -e 's|^\(\s*\)mallopt(M_ARENA_TEST, 2);|#ifdef M_ARENA_TEST\n\1mallopt(M_ARENA_TEST, 2);\n#endif|' \
        -e 's|^\(\s*\)mallopt(M_ARENA_MAX, 2);|#ifdef M_ARENA_MAX\n\1mallopt(M_ARENA_MAX, 2);\n#endif|' \
        -e 's|^\(\s*\)mallopt(M_MMAP_THRESHOLD, 128\*1024);|#ifdef M_MMAP_THRESHOLD\n\1mallopt(M_MMAP_THRESHOLD, 128*1024);\n#endif|' \
        "$f"
}

# ================================================================
# Patch 02 — src/libtools/signals.c: glibc-only NP 互斥锁初始化器
# ================================================================
# 报错:
#   error: use of undeclared identifier 'PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP'
#
# 原因:
#   PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP / RECURSIVE_MUTEX_INITIALIZER_NP
#   是 glibc 的私有静态初始化器, musl 不提供.
#
# 修法:
#   在 signals.c 顶部为这两个宏提供 fallback 定义,
#   值用普通 PTHREAD_MUTEX_INITIALIZER. errorcheck/recursive 行为差异
#   只影响错误检查/重入策略, 对 box64 信号路径没有功能影响.
patch_02_pthread_np() {
    local f="$BOX64/src/libtools/signals.c"
    local mark='OHOS_PATCH_PTHREAD_NP'

    [ -f "$f" ] || { _patch_header 02 "(skip) signals.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 02 "src/libtools/signals.c" "pthread NP init — already patched"
        return 0
    fi
    _patch_header 02 "src/libtools/signals.c" "fallback for ERRORCHECK/RECURSIVE_*_NP"

    sed -i "1i\\
/* $mark */\\
#include <pthread.h>\\
#ifndef PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP\\
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP\\
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif" "$f"
}

# ================================================================
# Patch 03 — fts.h / fts_*: 集成 musl-fts
# ================================================================
# 报错:
#   fatal error: 'fts.h' file not found
#   (出现在 src/libtools/auxval.c, src/libtools/myalign.c 等)
#
# 原因:
#   fts(3) 是 BSD 起源的目录遍历 API. glibc 提供了 fts.h / fts_open /
#   fts_read 等, musl 没有. box64 在多个地方包含 <fts.h>.
#
# 修法:
#   1. 浅克隆 https://github.com/void-linux/musl-fts
#   2. 把 fts.h 放到 src/include/fts.h         (满足 #include <fts.h>)
#   3. 把 fts.c 复制为 src/musl_fts.c          (提供实现)
#   4. 在 CMakeLists.txt 末尾追加 target_sources, 把 musl_fts.c 编进 box64
#
# 幂等性:
#   - 文件存在则跳过复制
#   - CMakeLists.txt 用唯一标记 OHOS_PATCH_FTS_TARGET 防重复
patch_03_fts() {
    local fts_repo="$THIRD_PARTY/musl-fts"
    local hdr_dst="$BOX64/src/include/fts.h"
    local src_dst="$BOX64/src/musl_fts.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_FTS_TARGET'

    _patch_header 03 "src/include/fts.h + src/musl_fts.c" "integrate musl-fts"

    _clone_shallow https://github.com/void-linux/musl-fts.git "$fts_repo"

    if [ ! -f "$fts_repo/fts.h" ] || [ ! -f "$fts_repo/fts.c" ]; then
        echo "    [#03] ERROR: musl-fts 源码不完整: $fts_repo"
        return 1
    fi

    if [ ! -f "$hdr_dst" ]; then
        cp "$fts_repo/fts.h" "$hdr_dst"
        echo "    [#03]   + $hdr_dst"
    fi
    if [ ! -f "$src_dst" ]; then
        cp "$fts_repo/fts.c" "$src_dst"
        echo "    [#03]   + $src_dst"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#03]   CMakeLists.txt — already patched"
    else
        echo "    [#03]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_FTS

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_fts.c)
endif()
# =========================================
EOF_FTS
    fi
}

# ================================================================
# Patch 04 — src/include/myalign.h: __sigset_t 在 musl 必须带 struct 标签
# ================================================================
# 报错:
#   error: must use 'struct' tag to refer to type '__sigset_t'
#       __sigset_t       __saved_mask;
#       ^
#       struct
#
# 原因:
#   glibc 把内部类型 __sigset_t 用 typedef 暴露成无标签类型, 可裸用.
#   musl 只暴露带 struct 标签的形式, 必须写 'struct __sigset_t' 或者
#   直接用 POSIX 公开类型 sigset_t (二者实现等价).
#
# 修法:
#   把 myalign.h 里的 '__sigset_t __saved_mask' 换成 'sigset_t __saved_mask'.
#   sigset_t 是 POSIX 标准类型, glibc/musl 都有, 不会再出兼容性问题.
patch_04_sigset_t() {
    local f="$BOX64/src/include/myalign.h"
    local mark='OHOS_PATCH_SIGSET_T'

    [ -f "$f" ] || { _patch_header 04 "(skip) myalign.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 04 "src/include/myalign.h" "__sigset_t — already patched"
        return 0
    fi
    _patch_header 04 "src/include/myalign.h" "__sigset_t -> sigset_t"

    sed -i "1i\\
/* $mark */" "$f"
    sed -i 's/^\(\s*\)__sigset_t\(\s\+__saved_mask\)/\1sigset_t\2/' "$f"
}

# ================================================================
# Patch 05 — src/libtools/threads.c: 删除与 musl 冲突的 cleanup 本地声明
# ================================================================
# 报错:
#   error: conflicting types for '_pthread_cleanup_push'
#   error: conflicting types for '_pthread_cleanup_pop'
#
# 原因:
#   box64 在 threads.c 顶部为 _pthread_cleanup_push / _pthread_cleanup_pop
#   写了一份"自定义"的前向声明, 想直接调用 glibc 内部 NPTL 实现.
#   musl 的 <pthread.h> 也声明了这俩内部函数, 但参数/返回类型不一样,
#   两份声明撞车, 编译失败.
#
# 修法:
#   把 threads.c 里这两行手写的前向声明删掉, 直接用 musl <pthread.h>
#   暴露的版本. 调用站点的实参类型已经匹配 musl, 不需要改动.
patch_05_pthread_cleanup() {
    local f="$BOX64/src/libtools/threads.c"
    local mark='OHOS_PATCH_PTHREAD_CLEANUP'

    [ -f "$f" ] || { _patch_header 05 "(skip) threads.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 05 "src/libtools/threads.c" "cleanup decls — already patched"
        return 0
    fi
    _patch_header 05 "src/libtools/threads.c" "drop conflicting _pthread_cleanup_* decls"

    sed -i "1i\\
/* $mark */" "$f"

    # 行尾可能带 // 注释, 用宽松匹配: 行内出现该函数名声明且以 ); 结尾即删
    sed -i \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_push[[:space:]]*(.*);/d' \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_pop[[:space:]]*(.*);/d' \
        "$f"
}

# ================================================================
# Patch 06 — obstack.h / obstack_*: 集成 musl-obstack
# ================================================================
# 报错:
#   fatal error: 'obstack.h' file not found
#       (出现在 src/libtools/obstack.c, 后续可能还有 obstack_* 链接错误)
#
# 原因:
#   obstack(3) 是 GNU libc 提供的"对象栈"分配器, musl 不提供
#   obstack.h 头文件, 也不提供 _obstack_begin / _obstack_newchunk
#   等运行时实现.
#
# 修法:
#   照搬 fts 的做法:
#   1. 浅克隆 https://github.com/void-linux/musl-obstack
#   2. obstack.h 放到 src/include/obstack.h    (满足 #include <obstack.h>)
#   3. obstack.c 复制为 src/musl_obstack.c     (提供运行时符号)
#   4. CMakeLists.txt 里 target_sources 把 musl_obstack.c 加入 box64
#
# 注:
#   musl-obstack 的 obstack.c 可能 #include "config.h", 如果之后报缺
#   config.h, 再加 patch 07 提供最小桩.
patch_06_obstack() {
    local repo="$THIRD_PARTY/musl-obstack"
    local hdr_dst="$BOX64/src/include/obstack.h"
    local src_dst="$BOX64/src/musl_obstack.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_OBSTACK_TARGET'

    _patch_header 06 "src/include/obstack.h + src/musl_obstack.c" "integrate musl-obstack"

    _clone_shallow https://github.com/void-linux/musl-obstack.git "$repo"

    if [ ! -f "$repo/obstack.h" ] || [ ! -f "$repo/obstack.c" ]; then
        echo "    [#06] ERROR: musl-obstack 源码不完整: $repo"
        return 1
    fi

    if [ ! -f "$hdr_dst" ]; then
        cp "$repo/obstack.h" "$hdr_dst"
        echo "    [#06]   + $hdr_dst"
    fi
    if [ ! -f "$src_dst" ]; then
        cp "$repo/obstack.c" "$src_dst"
        echo "    [#06]   + $src_dst"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#06]   CMakeLists.txt — already patched"
    else
        echo "    [#06]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_OBS

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_obstack.c)
endif()
# =========================================
EOF_OBS
    fi
}

# ================================================================
# Patch 07 — src/include/error.h: musl 不提供 <error.h>, 给最小 stub
# ================================================================
# 报错:
#   fatal error: 'error.h' file not found
#       (出现在 src/wrapped/wrappedlibc.c)
#
# 原因:
#   error(3) / error_at_line(3) 是 glibc 的 GNU 扩展, 用于命令行
#   工具风格的报错+退出. musl 不提供 <error.h>.
#
# 修法:
#   写一份纯头文件的 stub: 把 error()/error_at_line() 实现为 inline
#   函数, 内部用 vfprintf/strerror/exit. 行为和 glibc 等价, 不需要
#   单独的实现 .c 文件; 也不会引入新的链接依赖.
#
#   再放一个 musl_error.c 提供 error_message_count / error_one_per_line
#   / error_print_progname 这三个数据符号 (GNU error.h 文档要求, 个别
#   下游代码会读它们; box64 自己不读, 但同样集成进来零成本).
patch_07_error_h() {
    local hdr="$BOX64/src/include/error.h"
    local src="$BOX64/src/musl_error.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_ERROR_H_TARGET'

    _patch_header 07 "src/include/error.h + src/musl_error.c" "GNU <error.h> stub"

    if [ ! -f "$hdr" ]; then
        cat > "$hdr" << 'EOF_ERROR_H'
/*
 * Minimal <error.h> stub for OHOS musl.
 * Provides GNU error(3) / error_at_line(3) inline.
 */
#ifndef BOX64_OHOS_ERROR_H
#define BOX64_OHOS_ERROR_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

extern unsigned int error_message_count;
extern int          error_one_per_line;
extern void       (*error_print_progname)(void);

static inline void error(int status, int errnum, const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    if (error_print_progname) error_print_progname();
    else                      fputs("box64: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

static inline void error_at_line(int status, int errnum,
                                 const char *fname, unsigned int lineno,
                                 const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "%s:%u: ", fname ? fname : "?", lineno);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

#ifdef __cplusplus
}
#endif

#endif /* BOX64_OHOS_ERROR_H */
EOF_ERROR_H
        echo "    [#07]   + $hdr"
    fi

    if [ ! -f "$src" ]; then
        cat > "$src" << 'EOF_ERROR_C'
/* Data symbols required by GNU <error.h> contract. */
#include <stddef.h>
unsigned int error_message_count = 0;
int          error_one_per_line  = 0;
void       (*error_print_progname)(void) = NULL;
EOF_ERROR_C
        echo "    [#07]   + $src"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#07]   CMakeLists.txt — already patched"
    else
        echo "    [#07]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_ERR_CM

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_error.c)
endif()
# =========================================
EOF_ERR_CM
    fi
}

# ================================================================
# Patch 08 — src/wrapped/wrappedlibdl.c: glibc dlinfo() 常量
# ================================================================
# 报错:
#   error: use of undeclared identifier 'RTLD_DL_SYMENT'
#   error: use of undeclared identifier 'RTLD_DL_LINKMAP'
#
# 原因:
#   RTLD_DL_SYMENT / RTLD_DL_LINKMAP 是 glibc 的 dlinfo(3) 请求码,
#   定义在 glibc 私有的 <dlfcn.h> 段里. musl 整体不实现 dlinfo, 自然
#   也不暴露这俩宏.
#
#   box64 用它们来 wrap dlinfo() 调用, 让 guest 能查询动态库符号项 /
#   link map. 编译期需要这俩宏存在, 运行期实际调用 dlinfo() 时, 我们
#   将提供一个 weak stub 返回 -ENOSYS (后续在 musl_compat.c 里加).
#
# 修法 (编译期):
#   在 wrappedlibdl.c 顶部为这两个宏提供 fallback 数值定义.
#   值参考 glibc <bits/dlfcn.h>:
#       RTLD_DI_LINKMAP   = 2   -> RTLD_DL_LINKMAP
#       RTLD_DI_TLS_MODID = 9
#       RTLD_DI_TLS_DATA  = 10
#   实际 box64 只用了 RTLD_DL_SYMENT / RTLD_DL_LINKMAP, 给同样的整数
#   值就够编译通过. 运行期由 dlinfo() stub 直接返回 ENOSYS.
patch_08_dlinfo_consts() {
    local f="$BOX64/src/wrapped/wrappedlibdl.c"
    local mark='OHOS_PATCH_DLINFO_CONSTS'

    [ -f "$f" ] || { _patch_header 08 "(skip) wrappedlibdl.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 08 "src/wrapped/wrappedlibdl.c" "RTLD_DL_* — already patched"
        return 0
    fi
    _patch_header 08 "src/wrapped/wrappedlibdl.c" "fallback for RTLD_DL_SYMENT/LINKMAP"

    sed -i "1i\\
/* $mark */\\
#ifndef RTLD_DL_LINKMAP\\
#define RTLD_DL_LINKMAP 2\\
#endif\\
#ifndef RTLD_DL_SYMENT\\
#define RTLD_DL_SYMENT  1\\
#endif" "$f"
}

# ================================================================
# Patch 09 — src/wrapped/wrappedlibc.c: musl 兼容 (一锅端)
# ================================================================
# 报错(摘):
#   error: duplicate member 'fstat'/'stat'/'lstat'/'fopen'/'ftw'/...
#       (源自 musl 的 #define stat64 stat 之类宏, 跟 wrapper 表撞名)
#   error: use of undeclared identifier '__compar_d_fn_t'
#   error: indirection requires pointer operand ('int' invalid)
#       (lock.__data.__owner 之类 glibc 私有布局)
#   error: use of undeclared identifier 'PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP'
#   error: no member named '__data' in 'pthread_mutex_t'
#
# 修法 (4 步):
#   A) 文件顶部 prologue: 加 ctype/pthread 头, 补 __compar_d_fn_t typedef,
#      为 PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP 提供 fallback
#   B) 在每个 '#include "wrappercallback.h"' 之前: #undef 一批 *64 宏,
#      让 wrapper 表里的 stat / stat64 等成为不同符号名
#   C) 在每个 '#include "wrappercallback.h"' 之后: #define *64 = 非 *64,
#      让本文件后续直接调用 stat64() / fopen64() 等还能编译通过
#      (在 musl 上 *64 函数就是非 *64 的别名)
#   D) 把 lock.__data.__owner 这类 glibc 私有访问全部替换成 0
#
# 幂等性:
#   全部用唯一标记 OHOS_PATCH_WRAPPEDLIBC, 只打一次.
patch_09_wrappedlibc() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_WRAPPEDLIBC'

    [ -f "$f" ] || { _patch_header 09 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 09 "src/wrapped/wrappedlibc.c" "musl compat — already patched"
        return 0
    fi
    _patch_header 09 "src/wrapped/wrappedlibc.c" "prologue + wrap callback include + struct shim"

    # ---- A) 顶部 prologue ----
    sed -i "1i\\
/* $mark */\\
#include <ctype.h>\\
#include <pthread.h>\\
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP\\
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
#ifndef PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP\\
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
typedef int (*__compar_d_fn_t)(const void *, const void *, void *);\\
/* $mark END */" "$f"

    # ---- B) 在每个 include "wrappercallback.h" 之前 undef ----
    sed -i '/^#include "wrappercallback.h"/i\
/* OHOS_UNDEF_BEFORE_CB */\
#undef stat64\
#undef fstat64\
#undef lstat64\
#undef fstatat64\
#undef fopen64\
#undef ftw64\
#undef nftw64\
#undef scandir64\
#undef open64\
#undef mmap64\
/* OHOS_UNDEF_BEFORE_CB END */' "$f"

    # ---- C) 在每个 include "wrappercallback.h" 之后 redefine ----
    sed -i '/^#include "wrappercallback.h"/a\
/* OHOS_REDEF_AFTER_CB */\
#define stat64    stat\
#define fstat64   fstat\
#define lstat64   lstat\
#define fstatat64 fstatat\
#define fopen64   fopen\
#define ftw64     ftw\
#define nftw64    nftw\
#define scandir64 scandir\
#define open64    open\
#define mmap64    mmap\
/* OHOS_REDEF_AFTER_CB END */' "$f"

    # ---- D) glibc 私有 pthread_mutex_t 内部布局: 一律视为 0 ----
    sed -i \
        -e 's|lock\.__data\.__owner|0 /* musl: no __data.__owner */|g' \
        -e 's|lock\.__data\.__count|0 /* musl: no __data.__count */|g' \
        -e 's|lock\.__data\.__lock|0  /* musl: no __data.__lock  */|g' \
        "$f"
}

# ================================================================
# Patch 10 — src/wrapped/wrappedlibc.c: ctype 私有 + GNU sched.h 常量
# ================================================================
# 报错(本轮新增):
#   error: indirection requires pointer operand ('int' invalid)
#       *(__ctype_b_loc()) / __ctype_tolower_loc() / __ctype_toupper_loc()
#   error: use of undeclared identifier 'CLONE_NEWUSER'
#                                       'CLONE_VM' 'CLONE_VFORK' 'CLONE_SETTLS'
#
# 原因:
#   1) musl 的 <ctype.h> 不暴露 __ctype_*_loc() 系列 (glibc 私有). 没声明
#      时 clang 退化为 int 返回类型, 解引用直接编译失败.
#   2) musl 的 <sched.h> 把 CLONE_* 这一坨宏放在 _GNU_SOURCE 保护下;
#      clean baseline 没全局开 _GNU_SOURCE, 所以全部不可见.
#
# 修法:
#   - 文件最顶部 #ifndef _GNU_SOURCE / #define _GNU_SOURCE
#   - #include <sched.h>  让 CLONE_* 暴露
#   - 手写 __ctype_b_loc / tolower_loc / toupper_loc 三个函数声明
#     (运行期符号留给 musl_compat.c 提供 weak 实现)
#
# 注:
#   patch_09 已经在文件顶部插过一段, 这里再 1i 一次, 新内容会出现
#   在更靠前的位置, 不会冲突. 关键是 _GNU_SOURCE 必须先于任何
#   <sched.h> / 其它系统头展开.
patch_10_wrappedlibc_more() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_WRAPPEDLIBC_MORE'

    [ -f "$f" ] || { _patch_header 10 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 10 "src/wrapped/wrappedlibc.c" "ctype/CLONE — already patched"
        return 0
    fi
    _patch_header 10 "src/wrapped/wrappedlibc.c" "_GNU_SOURCE + sched.h + __ctype_*_loc decls"

    sed -i "1i\\
/* $mark */\\
#ifndef _GNU_SOURCE\\
#define _GNU_SOURCE\\
#endif\\
#include <sched.h>\\
extern const unsigned short **__ctype_b_loc(void);\\
extern const int **__ctype_tolower_loc(void);\\
extern const int **__ctype_toupper_loc(void);\\
/* $mark END */" "$f"
}

# ================================================================
# Patch 11 — src/include/config.h: 提供 autotools 风格的最小 config.h
# ================================================================
# 报错:
#   fatal error: 'config.h' file not found
#       (源自 src/musl_obstack.c, src/musl_fts.c)
#
# 原因:
#   musl-obstack 和 musl-fts 都是从 GNU autotools 项目剥离出来的,
#   源码顶部 '#include <config.h>'. config.h 是 autotools configure
#   阶段生成的产物, 列出 HAVE_* 探测结果. 我们没用 autotools, 没人
#   生成它.
#
# 修法:
#   手写一份最小 config.h 放到 src/include/. 内容是 OHOS musl 上
#   一定满足的 HAVE_* 列表 (dirent / fstatat / openat / dirfd 等
#   POSIX 接口都在). 这两份代码看到 HAVE_DIRENT_D_TYPE 之类的宏
#   被定义为 1, 就会走快路径; 没定义也只是走慢路径, 不影响功能.
#
# 注:
#   只对 musl-obstack / musl-fts 这两份外来代码有用. box64 自己的
#   .c 文件不会去 include <config.h>.
patch_11_config_h() {
    local hdr="$BOX64/src/include/config.h"

    if [ -f "$hdr" ] && grep -q 'BOX64_OHOS_MIN_CONFIG_H' "$hdr"; then
        _patch_header 11 "src/include/config.h" "minimal config.h — already patched"
        return 0
    fi

    _patch_header 11 "src/include/config.h" "minimal autotools-style config.h"

    cat > "$hdr" << 'EOF_CONFIG_H'
/*
 * Minimal config.h for musl-obstack and musl-fts on OHOS musl.
 * Hand-written substitute for what autotools' configure would produce.
 */
#ifndef BOX64_OHOS_MIN_CONFIG_H
#define BOX64_OHOS_MIN_CONFIG_H

/* --- standard headers --- */
#define HAVE_STDLIB_H        1
#define HAVE_STRING_H        1
#define HAVE_STRINGS_H       1
#define HAVE_UNISTD_H        1
#define HAVE_INTTYPES_H      1
#define HAVE_STDINT_H        1
#define HAVE_ERRNO_H         1
#define HAVE_FCNTL_H         1
#define HAVE_LIMITS_H        1
#define HAVE_MEMORY_H        1
#define HAVE_SYS_PARAM_H     1
#define HAVE_SYS_STAT_H      1
#define HAVE_SYS_TYPES_H     1
#define HAVE_DIRENT_H        1

/* --- functions / fields available on OHOS musl aarch64 --- */
#define HAVE_FSTATAT         1
#define HAVE_OPENAT          1
#define HAVE_FCHDIR          1
#define HAVE_DIRFD           1
#define HAVE_DIRENT_D_TYPE   1
#define HAVE_GETPAGESIZE     1
#define HAVE_MEMCPY          1
#define HAVE_MEMMOVE         1

/* --- generic macros some upstream projects expect --- */
#define STDC_HEADERS         1
#define _ALL_SOURCE          1

/* --- package strings (referenced by some upstream code) --- */
#define PACKAGE              "box64-ohos"
#define PACKAGE_NAME         "box64-ohos"
#define PACKAGE_VERSION      "1.0"
#define VERSION              "1.0"

#endif /* BOX64_OHOS_MIN_CONFIG_H */
EOF_CONFIG_H
}

# ================================================================
# Patch 12 — src/musl_compat.c: glibc-only 运行期符号 weak stub 一锅端
# ================================================================
# 报错(节选):
#   ld.lld: undefined symbol: __libc_malloc / __libc_free / __libc_calloc /
#                             __libc_realloc / __libc_memalign / dlinfo /
#                             pthread_*_affinity_np / pthread_mutexattr_*robust /
#                             obstack_vprintf / qsort_r / glob64 /
#                             scandirat / scandirat64 / __ctype_b_loc
#
# 原因:
#   这些都是 glibc 提供而 musl 不提供的符号. box64 的代码 (以及 musl-obstack
#   里) 直接引用了它们, 链接阶段 ld.lld 找不到实体 -> undefined symbol.
#
# 修法:
#   写一份 src/musl_compat.c, 用 weak 属性提供所有这些符号的兜底实现.
#   weak 的好处: 如果将来某个版本的 OHOS NDK / musl 补全了某个符号,
#   会自动覆盖我们的 stub, 不需要再改代码.
#
# 设计要点:
#   1. __libc_malloc 系列直接转发到 POSIX malloc/free/calloc/realloc/memalign
#   2. dlinfo 返回 -1 + errno=ENOSYS  (运行期 box64 走 fallback 路径)
#   3. pthread NP 扩展返回 ENOSYS 或 0  (CPU 亲和性等无法在沙箱里设置)
#   4. obstack_printf/vprintf 用 vsnprintf + obstack_grow 拼出来
#   5. qsort_r 用 thread-local 变量做跳板, 转给 qsort
#   6. glob64/globfree64 直接转给 glob/globfree (musl 上 off64_t == off_t)
#   7. scandirat/scandirat64 用 openat + fdopendir + readdir 手写
#   8. __ctype_b_loc 系列: 在 ctor 阶段填好 256 项表, 返回指向 +128 偏移的指针
#      (glibc 风格 -- 允许下标 -128..127)
patch_12_musl_compat() {
    local f="$BOX64/src/musl_compat.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_MUSL_COMPAT_TARGET'

    if [ -f "$f" ] && grep -q 'BOX64_OHOS_MUSL_COMPAT' "$f"; then
        _patch_header 12 "src/musl_compat.c" "weak symbol stubs — already patched"
    else
        _patch_header 12 "src/musl_compat.c" "weak stubs for glibc-only runtime symbols"
        cat > "$f" << 'EOF_MUSL_COMPAT'
/*
 * musl_compat.c — glibc-private symbol stubs for OHOS musl.
 *
 * All implementations are weak so that any future OHOS NDK update which
 * adds a real symbol will silently override these.
 */
#define _GNU_SOURCE
#define BOX64_OHOS_MUSL_COMPAT 1

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *memalign(size_t, size_t);  /* not in <stdlib.h> on musl */

/* ------------------------------------------------------------------
 * glibc-private __libc_* malloc family
 * ------------------------------------------------------------------ */
__attribute__((weak)) void *__libc_malloc (size_t s)            { return malloc(s); }
__attribute__((weak)) void  __libc_free   (void *p)             { free(p); }
__attribute__((weak)) void *__libc_calloc (size_t n, size_t s)  { return calloc(n, s); }
__attribute__((weak)) void *__libc_realloc(void *p, size_t s)   { return realloc(p, s); }
__attribute__((weak)) void *__libc_memalign(size_t a, size_t s) { return memalign(a, s); }
__attribute__((weak)) void *__libc_valloc (size_t s)
{
    return memalign(sysconf(_SC_PAGESIZE), s);
}
__attribute__((weak)) void *__libc_pvalloc(size_t s)
{
    long pg = sysconf(_SC_PAGESIZE);
    size_t r = (s + pg - 1) & ~(pg - 1);
    return memalign(pg, r);
}

/* ------------------------------------------------------------------
 * pthread NP extensions
 * ------------------------------------------------------------------ */
__attribute__((weak))
int pthread_attr_setaffinity_np(pthread_attr_t *a, size_t s, const void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_attr_getaffinity_np(const pthread_attr_t *a, size_t s, void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getaffinity_np(pthread_t t, size_t s, void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_setaffinity_np(pthread_t t, size_t s, const void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_setattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_mutexattr_getrobust(const pthread_mutexattr_t *a, int *r)
{ (void)a; if (r) *r = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setrobust(pthread_mutexattr_t *a, int r)
{ (void)a;(void)r; return 0; }

__attribute__((weak))
int pthread_mutexattr_getprioceiling(const pthread_mutexattr_t *a, int *p)
{ (void)a; if (p) *p = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setprioceiling(pthread_mutexattr_t *a, int p)
{ (void)a;(void)p; return ENOSYS; }

/* ------------------------------------------------------------------
 * dlinfo — musl doesn't ship one. Return ENOSYS.
 * ------------------------------------------------------------------ */
__attribute__((weak))
int dlinfo(void *handle, int request, void *info)
{
    (void)handle; (void)request; (void)info;
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------
 * qsort_r — thread-local trampoline to qsort
 * ------------------------------------------------------------------ */
typedef int (*qsort_r_compar_t)(const void *, const void *, void *);
static __thread qsort_r_compar_t g_qr_compar;
static __thread void            *g_qr_arg;

static int qsort_r_thunk(const void *a, const void *b)
{
    return g_qr_compar(a, b, g_qr_arg);
}

__attribute__((weak))
void qsort_r(void *base, size_t nmemb, size_t size,
             qsort_r_compar_t compar, void *arg)
{
    g_qr_compar = compar;
    g_qr_arg    = arg;
    qsort(base, nmemb, size, qsort_r_thunk);
}

/* ------------------------------------------------------------------
 * glob64 / globfree64 — on musl, off64_t == off_t, just forward.
 * ------------------------------------------------------------------ */
extern int  glob (const char *, int, int (*)(const char *, int), void *);
extern void globfree(void *);

__attribute__((weak))
int glob64(const char *pat, int flags,
           int (*errfunc)(const char *, int), void *pglob)
{
    return glob(pat, flags, errfunc, pglob);
}

__attribute__((weak))
void globfree64(void *pglob) { globfree(pglob); }

/* ------------------------------------------------------------------
 * scandirat / scandirat64
 * ------------------------------------------------------------------ */
__attribute__((weak))
int scandirat(int dirfd, const char *dirp,
              struct dirent ***namelist,
              int (*filter)(const struct dirent *),
              int (*compar)(const struct dirent **,
                            const struct dirent **))
{
    int fd = openat(dirfd, dirp, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    DIR *d = fdopendir(fd);
    if (!d) { close(fd); return -1; }

    struct dirent **list = NULL;
    int n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (filter && !filter(e)) continue;
        struct dirent *copy = (struct dirent *)malloc(sizeof(*e));
        if (!copy) { closedir(d); free(list); return -1; }
        memcpy(copy, e, sizeof(*e));
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            list = (struct dirent **)realloc(list, cap * sizeof(*list));
        }
        list[n++] = copy;
    }
    closedir(d);
    if (compar) {
        qsort(list, n, sizeof(*list),
              (int (*)(const void *, const void *))compar);
    }
    *namelist = list;
    return n;
}

__attribute__((weak))
int scandirat64(int dirfd, const char *dirp,
                struct dirent ***namelist,
                int (*filter)(const struct dirent *),
                int (*compar)(const struct dirent **,
                              const struct dirent **))
{
    return scandirat(dirfd, dirp, namelist, filter, compar);
}

/* ------------------------------------------------------------------
 * obstack_printf / obstack_vprintf — musl-obstack 不提供
 * ------------------------------------------------------------------ */
struct obstack;
extern void _obstack_grow_box(struct obstack *o, const void *data, size_t n);
/* (real implementation below uses obstack_grow which is a macro; include the
 *  obstack header for it.) */
#include "obstack.h"

__attribute__((weak))
int obstack_vprintf(struct obstack *obs, const char *fmt, va_list ap)
{
    char small[2048];
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    if (n >= 0 && (size_t)n < sizeof(small)) {
        obstack_grow(obs, small, n);
    } else if (n >= 0) {
        char *big = (char *)malloc(n + 1);
        if (big) {
            vsnprintf(big, n + 1, fmt, ap2);
            obstack_grow(obs, big, n);
            free(big);
        }
    }
    va_end(ap2);
    return n;
}

__attribute__((weak))
int obstack_printf(struct obstack *obs, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = obstack_vprintf(obs, fmt, ap);
    va_end(ap);
    return n;
}

/* ------------------------------------------------------------------
 * __ctype_b_loc / __ctype_tolower_loc / __ctype_toupper_loc
 * Allocate 384-entry tables; return pointer offset by +128 so callers
 * can index in [-128, 255] like glibc does.
 * ------------------------------------------------------------------ */
#define BOX_ISupper  0x0100
#define BOX_ISlower  0x0200
#define BOX_ISalpha  0x0400
#define BOX_ISdigit  0x0800
#define BOX_ISxdigit 0x1000
#define BOX_ISspace  0x2000
#define BOX_ISprint  0x4000
#define BOX_ISgraph  0x8000
#define BOX_ISblank  0x0001
#define BOX_IScntrl  0x0002
#define BOX_ISpunct  0x0004
#define BOX_ISalnum  0x0008

static unsigned short box_ctype_b      [384];
static int            box_ctype_tolower[384];
static int            box_ctype_toupper[384];

static const unsigned short *box_ctype_b_ptr       = box_ctype_b       + 128;
static const int            *box_ctype_tolower_ptr = box_ctype_tolower + 128;
static const int            *box_ctype_toupper_ptr = box_ctype_toupper + 128;

__attribute__((constructor(102)))
static void box_init_ctype_tables(void)
{
    for (int c = 0; c < 256; c++) {
        unsigned short f = 0;
        if (c == ' ' || c == '\t')      f |= BOX_ISblank;
        if (c >= 0x09 && c <= 0x0D)     f |= BOX_ISspace;
        if (c == ' ')                   f |= BOX_ISspace;
        if (c < 0x20 || c == 0x7F)      f |= BOX_IScntrl;
        if (c >= 'A' && c <= 'Z')       f |= BOX_ISupper | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= 'a' && c <= 'z')       f |= BOX_ISlower | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= '0' && c <= '9')       f |= BOX_ISdigit | BOX_ISalnum | BOX_ISxdigit | BOX_ISprint | BOX_ISgraph;
        if ((c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F'))     f |= BOX_ISxdigit;
        if (c >= 0x21 && c <= 0x7E && !(f & BOX_ISalnum))
            f |= BOX_ISpunct | BOX_ISprint | BOX_ISgraph;
        if (c == ' ')                   f |= BOX_ISprint;

        box_ctype_b      [c + 128] = f;
        box_ctype_tolower[c + 128] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
        box_ctype_toupper[c + 128] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
    }
}

__attribute__((weak))
const unsigned short **__ctype_b_loc(void)
{
    return (const unsigned short **)&box_ctype_b_ptr;
}

__attribute__((weak))
const int **__ctype_tolower_loc(void)
{
    return (const int **)&box_ctype_tolower_ptr;
}

__attribute__((weak))
const int **__ctype_toupper_loc(void)
{
    return (const int **)&box_ctype_toupper_ptr;
}

/* ------------------------------------------------------------------
 * Misc math helpers some box64 code may reference
 * ------------------------------------------------------------------ */
__attribute__((weak)) int isnanf (float x) { return __builtin_isnan(x); }
__attribute__((weak)) int isinff (float x) { return __builtin_isinf(x); }
__attribute__((weak)) int finitef(float x) { return __builtin_isfinite(x); }

__attribute__((weak)) double      exp10 (double x)      { return pow (10.0,  x); }
__attribute__((weak)) float       exp10f(float x)       { return powf(10.0f, x); }
__attribute__((weak)) long double exp10l(long double x) { return powl(10.0L, x); }
EOF_MUSL_COMPAT
        echo "    [#12]   + $f"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#12]   CMakeLists.txt — already patched"
    else
        echo "    [#12]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_MUSL_CM

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_compat.c)
endif()
# =========================================
EOF_MUSL_CM
    fi
}

# ================================================================
# Patch 13 — src/mallochook.c: 暂时整文件替换为直接 libc 转发
# ================================================================
# 目的:
#   验证 mallochook 是不是启动期 100% CPU 用户态死循环的根源.
#   现象:
#     wchan=0, syscall=none, utime 持续增长, 单线程, 无任何 stderr,
#     十几分钟跑下来仍然如此.  典型的用户态自旋特征.
#   嫌疑:
#     mallochook 在 ctor 阶段会建立 box 内部内存池, 用原子 + spin
#     做并发保护. 如果初始化顺序错位, 第一个调到 box_malloc 的人
#     会在 spin 里等一个永远不会被 set 的 ready flag.
#
# 修法 (诊断用, 暂时性):
#   把整个 mallochook.c 换成 box_* -> libc malloc/free 的直接转发,
#   彻底绕开 box64 自己的内存池. 编译/链接通过, 启动期不再做任何
#   spin. 用这个版本跑 box64 看是否还卡:
#     - 不卡了    -> 锁定 mallochook 是元凶, 后续做正确移植
#     - 仍然卡    -> 不是 mallochook, 下一步去查 DynaRec 池 init /
#                    wrapped 表 init / cpu_info init 等其它 ctor
#
# 风险:
#   box64 翻译 x86 程序时需要 hook guest 的 malloc/free 来管理 guest
#   堆与 host 堆的隔离. 直接转发会丢失这个能力, 不能用于真正运行
#   x86 程序. 这条 patch 仅用于"box64 自身能不能启动"的诊断阶段.
patch_13_disable_mallochook() {
    local f="$BOX64/src/mallochook.c"
    local mark='OHOS_PATCH_DISABLE_MALLOCHOOK'

    [ -f "$f" ] || { _patch_header 13 "(skip) mallochook.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 13 "src/mallochook.c" "mallochook — already replaced"
        return 0
    fi
    _patch_header 13 "src/mallochook.c" "REPLACE with libc passthrough (DIAGNOSTIC)"

cat > "$f" << 'EOF_MH'
/* OHOS_PATCH_DISABLE_MALLOCHOOK -- diagnostic passthrough.
 *
 * 原始 mallochook 用一组 box64 内部内存池 + spin lock 接管所有
 * malloc/free, 怀疑它在 OHOS musl 上的 ctor 阶段死循环.
 *
 * 此版本完全绕开内存池逻辑: 所有 box_* 函数直接转给 libc.
 * 仅用于定位启动期死循环, 不可用于真正翻译 x86 程序.
 */
#include <limits.h>
#include <stdlib.h>
#include <string.h>

extern void *memalign(size_t, size_t);

/* ---------- 基础 box_* 分配族 ---------- */
void *box_malloc(size_t s)                  { return malloc(s); }
void  box_free(void *p)                     { free(p); }
void *box_calloc(size_t n, size_t s)        { return calloc(n, s); }
void *box_realloc(void *p, size_t s)        { return realloc(p, s); }
void *box_memalign(size_t a, size_t s)      { return memalign(a, s); }
char *box_strdup(const char *s)             { return s ? strdup(s) : NULL; }
char *box_strndup(const char *s, size_t n)  { return s ? strndup(s, n) : NULL; }

/* 部分 box64 内部入口的最小桩 */
void   box_free_internal(void *p)              { free(p); }
size_t box_malloc_usable_size(void *p)         { (void)p; return 0; }

/* ---------- box64 启停 hook (诊断版本: 全部空操作) ---------- */
/* 原版会安装/卸载全局 malloc 拦截器, 这里全部 no-op,
 * 让 box64 主流程可以跑下去. */
void init_malloc_hook(void)  {}
void startMallocHook(void)   {}
void endMallocHook(void)     {}

/* checkHookedSymbols: 原版用于扫描刚加载的 ELF 的 dynsym 表,
 * 把命中我们感兴趣的符号 (malloc/free 等) 替换成 box_* 实现.
 * 诊断版本不需要做任何事 -- 我们已经不再 hook 全局 malloc.
 * 第二参数原型一般是 elfheader_t* / SymbolMap*, 用 void* 兼容.
 */
void checkHookedSymbols(void *symbols, void *h)
{
    (void)symbols; (void)h;
}

/* box_realpath: 路径解析 + 失败时退化为原始路径,
 * 保证非 NULL 返回 (box64 多处调用站点不检查 NULL). */
char *box_realpath(const char *path, char *resolved)
{
    if (!path) return NULL;

    char buf[PATH_MAX];
    char *target = resolved ? resolved : buf;
    char *r = realpath(path, target);

    if (r) {
        return resolved ? r : strdup(buf);
    }

    /* realpath 失败 (文件不存在 / 权限 / 等) -- 退化为原始字符串.
     * 不要返回 NULL, box64 上层不做空指针检查. */
    if (resolved) {
        size_t n = strlen(path);
        if (n >= PATH_MAX) n = PATH_MAX - 1;
        memcpy(resolved, path, n);
        resolved[n] = '\0';
        return resolved;
    }
    return strdup(path);
}

/* 不再用强符号覆盖系统 malloc/free, 让 musl 自己处理 */
EOF_MH
}

# ================================================================
# Patch 15 — src/custommem.c: 跳过 glibc 私有的 __curbrk 探测
# ================================================================
# 报错:
#   SIGSEGV @ pc=0  返回地址在 init_custommem_helper (custommem.c:3131)
#   addr2line: main -> initialize -> init_custommem_helper -> [pc 0]
#
# 原因:
#   line 3131 是  cur_brk = dlsym(RTLD_NEXT, "__curbrk");
#   __curbrk 是 glibc 私有的 program-break 跟踪指针, musl 完全没有.
#   而 musl 上从主可执行文件 (非 dlopen 加载的库) 调
#   dlsym(RTLD_NEXT, ...) 行为是 undefined; OHOS musl 表现是
#   走到一条空 PLT, 跳到地址 0 -> SIGSEGV.
#
#   --version 路径在 banner 之后立刻 return, 不会调用
#   init_custommem_helper, 所以那条路过. execve 真实 ELF 走完整
#   初始化流程, 必然命中此处.
#
# 修法:
#   把这行替换成  cur_brk = NULL;
#   musl 没有 brk 跟踪机制, box64 用 cur_brk 的地方 (主要是 sbrk
#   emulation) 在 NULL 时会走 fallback 路径. 静态 x86 程序基本
#   不调 sbrk, 没影响. 后续如果跑到 sbrk-heavy 的程序再做更细的
#   兼容; 现在先让 init_custommem_helper 能跑过去.
patch_15_custommem_no_curbrk() {
    local f="$BOX64/src/custommem.c"
    local mark='OHOS_PATCH_NO_CURBRK'

    [ -f "$f" ] || { _patch_header 15 "(skip) custommem.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 15 "src/custommem.c" "skip __curbrk — already patched"
        return 0
    fi
    _patch_header 15 "src/custommem.c" "drop dlsym(RTLD_NEXT, \"__curbrk\")"

    sed -i 's|cur_brk = dlsym(RTLD_NEXT, "__curbrk");|/* OHOS_PATCH_NO_CURBRK: musl has no __curbrk */ cur_brk = NULL;|' "$f"
}

# ================================================================
# Patch 16 — 全局 RTLD_NEXT -> RTLD_DEFAULT (musl 主程序兼容)
# ================================================================
# 报错:
#   崩在 NewBox64Context 218~225 行附近, 调用了一个 NULL 函数指针.
#
# 原因:
#   musl 上从主可执行文件 (非 LD_PRELOAD 加载的库) 调
#       dlsym(RTLD_NEXT, ...)
#   行为是 undefined: 大多数情况返回 NULL, 个别情况返回一条空 PLT
#   后跳到 0. box64 在多处用 RTLD_NEXT 拿"真"libc 函数:
#     - libtools/libdl.c     real_dlopen / real_dlclose / real_dlsym
#     - os/os_linux.c        libc_mmap64 / libc_munmap
#   这些指针拿到 NULL, 后续被调用就 SIGSEGV 跳到地址 0.
#
# 修法:
#   把所有 RTLD_NEXT 替换成 RTLD_DEFAULT.
#   - RTLD_NEXT  : 在调用方 ELF 之后的库里查找
#   - RTLD_DEFAULT: 全局符号搜索 (默认顺序)
#   box64 使用 RTLD_NEXT 的初衷只是"绕过自己 wrap 的版本拿 libc 原版",
#   而我们的诊断版 mallochook 已经不再 wrap 全局 malloc/free, 所以
#   RTLD_DEFAULT 直接返回 musl 的 libc 实现, 语义等价.
patch_16_rtld_next_to_default() {
    local mark='OHOS_PATCH_RTLD_DEFAULT'

    # 找出所有引用 RTLD_NEXT 的源文件 (排除已打过的)
    local files
    files=$(grep -rl 'RTLD_NEXT' "$BOX64/src" 2>/dev/null)
    if [ -z "$files" ]; then
        _patch_header 16 "(no RTLD_NEXT references)" ""
        return 0
    fi

    local any_done=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if grep -q "$mark" "$f" 2>/dev/null; then
            continue
        fi
        if grep -q '\bRTLD_NEXT\b' "$f"; then
            _patch_header 16 "${f#$BOX64/}" "RTLD_NEXT -> RTLD_DEFAULT"
            sed -i "1i\\
/* $mark */" "$f"
            sed -i 's/\bRTLD_NEXT\b/RTLD_DEFAULT/g' "$f"
            any_done=1
        fi
    done <<< "$files"

    if [ "$any_done" -eq 0 ]; then
        _patch_header 16 "(all RTLD_NEXT files already patched)" ""
    fi
}

# ================================================================
# Patch 17 — src/box64context.c: 跳过 dlopen(NULL, ...) 自引用
# ================================================================
# 报错:
#   崩在 box64context.c:219
#       context->box64lib = dlopen(NULL, RTLD_NOW|RTLD_GLOBAL);
#   反汇编:
#       7b4ce4: bl 0xd89cc8 <dlopen>     ← box64 自己 wrap 的 dlopen
#       内部 PC=0
#
# 原因:
#   box64 在 wrappedlibdl.c 里 EXPORT 了一个名为 'dlopen' 的强符号,
#   用来 wrap libc 的 dlopen. 主程序调 dlopen 时, ld 把它链到 box64
#   自己这版 wrap, wrap 里需要一个 'real_dlopen' 函数指针 (通过
#   dlsym 拿真 libc 实现).
#
#   musl 上从主程序解析 'dlopen' 时, 优先级让它解析回 box64 自己
#   export 的 dlopen, real_dlopen 拿到 NULL 或自身地址 -> NULL 调用.
#
# 修法:
#   box64lib 这个句柄的用途是 dlsym 查 box64 自身 export 的函数.
#   我们诊断阶段不依赖这条路径, 直接设为 NULL. 后续真要用到时,
#   box64 多处会做 NULL guard, 拿不到就走 fallback.
patch_17_skip_box64lib_dlopen() {
    local f="$BOX64/src/box64context.c"
    local mark='OHOS_PATCH_SKIP_BOX64LIB'

    [ -f "$f" ] || { _patch_header 17 "(skip) box64context.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 17 "src/box64context.c" "skip box64lib dlopen — already patched"
        return 0
    fi
    _patch_header 17 "src/box64context.c" "set box64lib = NULL (avoid self-recursive dlopen)"

    sed -i 's#context->box64lib = dlopen(NULL, RTLD_NOW|RTLD_GLOBAL);#/* OHOS_PATCH_SKIP_BOX64LIB */ context->box64lib = NULL;#' "$f"
}

# ================================================================
# Patch 18 — src/libtools/threads.c: 跳过 glibc 私有 pthread 符号 dlsym
# ================================================================
# 报错:
#   崩在 init_pthread_helper @ threads.c:1335
#   反汇编: bl 0xd89fbc <dlsym>
#   原因: box64 EXPORT 了 dlsym 强符号 wrap, 主程序调 dlsym(NULL,...)
#   走到 box64 自己的 wrap, 内部递归找 real_dlsym 时跳到 0.
#
# 即使 dlsym 调用本身没问题, 这几个被查的符号在 musl 上也全部不存在:
#   - _pthread_cleanup_push_defer    glibc 私有
#   - _pthread_cleanup_pop_restore   glibc 私有
#   - pthread_cond_clockwait         glibc 2.30+, musl 接口不同
#   - dlvsym(NULL,"pthread_kill","GLIBC_2.X")  musl 无符号版本化
#
# 修法:
#   直接把这一段 dlsym/dlvsym 查找改成把对应 real_* 指针赋 NULL.
#   box64 在使用 real_pthread_cleanup_*/cond_clockwait/kill_old 之前
#   都有 NULL guard, NULL 时走 fallback (调用普通 pthread_kill 等).
patch_18_skip_pthread_dlsym() {
    local f="$BOX64/src/libtools/threads.c"
    local mark='OHOS_PATCH_SKIP_PTHREAD_DLSYM'

    [ -f "$f" ] || { _patch_header 18 "(skip) threads.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 18 "src/libtools/threads.c" "skip pthread dlsym — already patched"
        return 0
    fi
    _patch_header 18 "src/libtools/threads.c" "replace dlsym(NULL,...) block with NULL assigns"

    # 三行 dlsym 直接 -> NULL
    sed -i \
        -e 's|real_pthread_cleanup_push_defer = (vFppp_t)dlsym(NULL, "_pthread_cleanup_push_defer");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cleanup_push_defer = NULL;|' \
        -e 's|real_pthread_cleanup_pop_restore = (vFpi_t)dlsym(NULL, "_pthread_cleanup_pop_restore");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cleanup_pop_restore = NULL;|' \
        -e 's|real_pthread_cond_clockwait = (iFppip_t)dlsym(NULL, "pthread_cond_clockwait");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cond_clockwait = NULL;|' \
        "$f"

    # 那段 for 循环 + dlvsym 找老版本 pthread_kill: 直接跳过整个查找,
    # 让代码走 "if (!real_phtread_kill_old) ... = pthread_kill" 兜底分支
    # 用 awk 把从 'search for older symbol' 到 '"GLIBC_2.2.5");' 之间整段注释掉
    awk '
        BEGIN { skip = 0 }
        /search for older symbol for pthread_kill/ { skip = 1 }
        skip {
            print "/* " $0 " */"
            if (/"GLIBC_2\.2\.5"\);/) skip = 0
            next
        }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ================================================================
# Patch 19 v3 — wrappedlibc.c: 禁用 PRE_INIT 里的 dlopen(NULL,...)
# ================================================================
# 现象:
#   wrappedlibc_init 的 PRE_INIT 宏展开成
#       lib->w.lib = dlopen(NULL, RTLD_LAZY|RTLD_GLOBAL);
#   这个调用进入 box64 自己 export 的 dlopen trampoline,
#   trampoline 在 musl 环境下 cache 写不上, br 0 → SIGSEGV.
#
# 修法:
#   把 PRE_INIT 改成空宏. 这一步原本是想拿主程序的句柄做 fallback
#   符号查找; musl 上 dlopen(NULL,...) 语义不同, 后续 wrappedlib_init
#   走 dlopen(libcName,...) 也能让 lib->w.lib 拿到非 NULL handle.
#
# 注意:
#   即使改空, dlopen("libc.so",...) 那一行仍然会进 trampoline,
#   后续可能在 my_dlopen 递归加载 libc 处再爆.  这条 patch 只是把
#   死亡点从 PRE_INIT 推到下一关, 方便观察新栈.
patch_19_no_pre_init_dlopen() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_NO_PRE_INIT_DLOPEN'
    [ -f "$f" ] || return 0
    if _already "$f" "$mark"; then
        _patch_header 19 "src/wrapped/wrappedlibc.c" "PRE_INIT noop — already"
        return 0
    fi
    _patch_header 19 "src/wrapped/wrappedlibc.c" "neutralize PRE_INIT dlopen(NULL,...)"

    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

# 匹配整个 #ifndef STATICBUILD ... #endif 包住的 PRE_INIT 定义块,
# 替换成"PRE_INIT 定义为空"——模板里 PRE_INIT 后紧跟 '{',
# 空展开后那个 '{' 就是普通块开始, 编译合法.
pat = re.compile(
    r"#ifndef\s+STATICBUILD\s*\n"
    r"#define\s+PRE_INIT.*?dlopen\s*\(\s*NULL[^;]*;\s*\\\s*\n"
    r"\s*else\s*\n"
    r"#endif",
    re.S)

repl = ("/* %s */\n"
        "/* PRE_INIT was: dlopen(NULL,...) -- disabled on OHOS musl, */\n"
        "/* see patch 19 notes. Empty macro is fine because the */\n"
        "/* template uses bare 'PRE_INIT' with no trailing ';' and the */\n"
        "/* following '{' becomes a plain compound statement.        */\n"
        "#define PRE_INIT" % mark)

if not pat.search(s):
    print("WARN: PRE_INIT block not found", file=sys.stderr); sys.exit(0)
s = pat.sub(repl, s, count=1)
open(p, 'w').write(s)
print("OK")
PY
}

# ================================================================
# Patch 20 — src/libtools/libdl.c: 降级 EXPORT 为 static
# ================================================================
# 现象:
#   libtools/libdl.c 里 EXPORT 出来的 dlopen / dlsym / dlclose / ...
#   是一组转发 shim, 内部缓存 'real_dlopen' 等函数指针, 用
#   GetNativeSymbolUnversioned(RTLD_DEFAULT,"dlopen") 取真 libc 实现.
#   OHOS musl 上这条路返回 0, cache 写 0, br x2 → SIGSEGV @0.
#
#   只要 box64 host 代码里有任何一处调 dlopen() / dlsym() / ...,
#   就会被 linker 解析到这组 shim, 就会爆.  PRE_INIT 改空之后,
#   wrappedlib_init.h:176 的 dlopen("libc.so",...) 又中招.
#
# 修法:
#   把 libdl.c 顶部的 EXPORT 宏覆盖成 'static __attribute__((unused))'.
#   原本是全局强符号的几个 dl* 函数变成本 .o 私有, 其它 .o 看不到,
#   linker 在解析 host 代码里的 dlopen()/dlsym()/... 时找不到本模块
#   定义, 直接通过 PLT 解析到 musl libc 真版本.
#
# 影响:
#   - host 代码 dlopen()/dlsym()/dlclose() 调用 → musl libc 真实现 ✓
#   - guest x86 程序的 dlopen 走 wrappedlibdl.c::my_dlopen, 不依赖
#     这组 trampoline, 完全不受影响 ✓
#   - box64 二进制的动态导出表里不再有 'dlopen' 等同名强符号,
#     如果设备上有别的 .so 通过 dlsym(box64_handle,"dlopen") 找符号
#     会失败 — 但实际场景没人这么做.
patch_20_libdl_rename_shims() {
    local f="$BOX64/src/libtools/libdl.c"
    local mark='OHOS_PATCH_LIBDL_RENAME_SHIMS'
    [ -f "$f" ] || return 0
    if _already "$f" "$mark"; then
        _patch_header 20 "src/libtools/libdl.c" "rename dl* shims — already"
        return 0
    fi
    _patch_header 20 "src/libtools/libdl.c" "rename dl* shims to _unused (host -> musl PLT)"

    sed -i "1i\\
/* $mark */" "$f"

    # 关键: 直接把函数名改掉, 让 box64 binary 不再定义这几个全局符号.
    # host 代码里所有 dlopen/dlsym/dlclose 调用因为本 binary 找不到
    # 定义, linker 会通过 PLT 解析到 musl libc 真 dlopen.
    #
    # 这几个 shim 本身是死代码 (没人会再调用它们), 加 unused 属性避免
    # clang 报 unused-function 警告 (我们已经全局 -Wno-unused-function,
    # 但保留属性方便 grep).
    sed -i \
        -e 's|^EXPORT void\* dlopen(|__attribute__((unused)) static void* box64_unused_dlopen(|' \
        -e 's|^EXPORT int dlclose(|__attribute__((unused)) static int box64_unused_dlclose(|' \
        -e 's|^EXPORT void\* dlsym(|__attribute__((unused)) static void* box64_unused_dlsym(|' \
        -e '/^EXPORT void\* ___dlsym.*alias.*dlsym.*;/d' \
        "$f"

    # 同步把它们内部的递归引用 (有的话) 也改掉; 简单起见直接全删 alias 行.
    # 实际 libdl.c 里这三个函数互不调用, 改完即可.
}

# ================================================================
# 调度
# ================================================================
echo "==> apply patches in: $BOX64"

patch_01_mallopt
patch_02_pthread_np
patch_03_fts
patch_04_sigset_t
patch_05_pthread_cleanup
patch_06_obstack
patch_07_error_h
patch_08_dlinfo_consts
patch_09_wrappedlibc
patch_10_wrappedlibc_more
patch_11_config_h
patch_12_musl_compat
patch_13_disable_mallochook
patch_15_custommem_no_curbrk
patch_16_rtld_next_to_default
patch_17_skip_box64lib_dlopen
patch_18_skip_pthread_dlsym
patch_19_no_pre_init_dlopen
patch_20_libdl_rename_shims

echo "    all patches applied."