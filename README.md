# HarmonyBox

Box64 for HarmonyOS NEXT — 在鸿蒙 PC 上运行 x86_64 Linux 程序

本仓库是 [Box64](https://github.com/ptitSeb/box64) 移植到 HarmonyOS NEXT 的
meta 仓库,包含完整的交叉编译脚本、20 余条针对 OHOS musl 的 patch、HAP 工程
模板、HNP 打包配方,以及调试工具。

> 💡 **关于本项目**
> 本项目高度依赖 AI 辅助 (Vibe Coding) 完成,包括这份文档也是 AI 帮忙润色的。
> 移植仍处于早期阶段,可能存在各种坑,请带着探索的心态体验。欢迎 issue 和 PR。

> ⚠️ **平台限制**
> - 仅支持搭载 HarmonyOS NEXT 的鸿蒙 PC (内核需要 39 位地址空间 + LSE/ASIMDDP 指令集)
> - 手机和平板暂未测试 (HNP 在非 PC 设备上的支持状态未知)
> - 由于 HAP 自签名流程的限制,本仓库不提供预编译 HAP

## 目录
- [当前状态](#当前状态)
- [仓库结构](#仓库结构)
- [构建前准备](#构建前准备)
- [构建流程](#构建流程)
- [测试验证](#测试验证)
- [HAP 集成](#hap-集成)
- [Patch 索引](#patch-索引)
- [调试工具](#调试工具)
- [致谢](#致谢)
- [License](#license)

## 当前状态

| 类型              | 状态 | 备注                                     |
|-------------------|------|------------------------------------------|
| musl  / dynamic   | ✅   | 14/14 测试通过                           |
| glibc / dynamic   | ✅   | 14/14 测试通过                           |
| musl  / static    | ⚠️   | signal handler 不兼容             |
| glibc / static    | ❌   | box64 上游已知限制                       |
| 多线程 (pthread)  | ✅   | create/join/mutex 均通过                 |
| 文件 IO           | ✅   | fopen/fread/fstat 通过                   |
| signal            | ✅   | dynamic ELF 上 sigaction 可用            |
| 浮点 / SIMD       | ✅   | FPU/SSE 路径通                           |
| DynaRec           | ✅   | 启用,Kirin 9010 上含 ASIMD/AES/CRC32... |

## 仓库结构

```
HarmonyBox/
├── README.md
├── LICENSE                              # MIT
├── .gitignore
│
├── scripts/
│   ├── build.sh                         # 主编译脚本
│   ├── patches.sh                       # 全部 20 条 patch (你的核心成果)
│   ├── build_hello.sh                   # 辅助: 编 hello world 测试
│   ├── build_test.sh                    # 辅助: 编功能测试
│   └── resolve.py                       # box64 崩溃地址解析工具
│
├── src/
│   ├── hello.c                          # 最小 hello world
│   └── test_box64.c                     # 14 项功能测试程序
│
├── hap/                                 # HAP 工程模板
│   ├── entry/
│   │   ├── src/main/
│   │   │   ├── cpp/
│   │   │   │   ├── napi_init.cpp        # box64 异步执行器 + rawfile 解包
│   │   │   │   ├── types/libentry/
│   │   │   │   │   └── Index.d.ts
│   │   │   │   └── CMakeLists.txt
│   │   │   ├── ets/pages/Index.ets
│   │   │   └── resources/rawfile/.gitkeep   # guest ELF 放这里
│   │   └── ...
│   └── README.md                        # 描述如何用 DevEco Studio 打开
│
├── hnp/
│   └── arm64-v8a/.gitkeep               # build_box64_ohos_clean.sh 输出目标
│
├── docs/
│   ├── PATCHES.md                       # 20 条 patch 的完整说明 (从 patches.sh 注释提取)
│   ├── ABI_NOTES.md                     # OHOS musl ABI 兼容性观察 (从 abitest 结果提炼)
│   └── DEBUGGING.md                     # 调试 box64 崩溃的手册 (resolve.py 用法)
│
└── thirdparty/                          # 不入库, 由脚本克隆
    └── .gitkeep
```

## 构建前准备

### 推荐环境
- WSL2 Ubuntu 22.04/24.04 或原生 Linux
- 磁盘空间 ≥ 5 GB
- HarmonyOS Native SDK (从 [开发者官网](...) 下载)

### 必备工具
```bash
sudo apt install -y build-essential cmake ninja-build python3 git zip unzip
```

### 环境变量
```bash
export OHOS_SDK=~/ohos-sdk/linux
```

## 构建流程

### 1. 克隆仓库
```bash
git clone https://github.com/panedioic/HarmonyBox.git
cd HarmonyBox
```

### 2. 拉取 box64 源码
```bash
git clone https://github.com/ptitSeb/box64.git
```

### 3. 编译
```bash
bash scripts/build.sh --reset-source
```

输出在 `out/box64`,HNP 包在 `out/box64.hnp`。脚本会自动应用 20 余条 patch
(详见 [docs/PATCHES.md](docs/PATCHES.md))。

### 4. 编译测试程序
```bash
# 准备 x86_64 musl 工具链
# 推荐: https://musl.cc/x86_64-linux-musl-cross.tgz
export MUSL_CC=~/x86_64-linux-musl-cross/bin/x86_64-linux-musl-gcc

bash scripts/build_test.sh
```

## 测试验证

### 在 WSL 本地验证 (基准)
build_test.sh 末尾会自动跑一次,3 份产物都应该 14/14 PASS。

### 在设备上验证
1. 把 `out/box64.hnp` 拷到 HAP 工程的 `hnp/arm64-v8a/`
2. 把 `test_box64_*` 拷到 HAP 工程的 `entry/src/main/resources/rawfile/`
3. DevEco Studio 安装 HAP
4. 在 hap UI 触发 `testNapi.runBox64(resmgr, filesDir, 'test_box64_musl_dyn')`
5. `hdc hilog | grep Box64Runner` 看输出

期望: musl_dyn / glibc_dyn 各 14/14 PASS,musl_static 13/14。

## HAP 集成

之后补充

## 调试工具

[scripts/resolve.py](scripts/resolve.py) — 把 box64 崩溃栈喂进去,自动跑
addr2line 反查每个 PC。

```bash
hdc hilog | grep Box64Runner | python3 scripts/resolve.py
# 或
python3 scripts/resolve.py --pc 0xe6e1b8 --asm
```

## 未来工作

- [ ] box86支持

## 致谢

- [Box64](https://github.com/ptitSeb/box64) — 上游项目, ptitSeb 等贡献者
- [OpenHarmony](https://gitee.com/openharmony) — 操作系统平台
- [musl-fts](https://github.com/void-linux/musl-fts) /
  [musl-obstack](https://github.com/void-linux/musl-obstack) — 补全 musl 缺失 API
- 以及背后默默贡献的开源社区与帮我写代码的 AI

## License

本仓库中新编写的脚本、patch、HAP 模板采用 [GPL License](LICENSE)。

第三方组件遵循其原始许可证:

| 组件          | 许可证        |
|---------------|---------------|
| Box64         | MIT           |
| musl-fts      | BSD-2-Clause  |
| musl-obstack  | LGPL-2.1+     |

⚠️ musl-obstack 是 LGPL,本项目通过 patch 06 将其源码集成到 box64 二进制中。
虽然本仓库没有提供二进制文件，但为了方便，还是一同采用 GPL 许可证。