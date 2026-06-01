# HarmonyBox

Box64 for HarmonyOS NEXT — Run x86_64 Linux programs on HarmonyOS PCs

This repository is a meta repository for porting [Box64](https://github.com/ptitSeb/box64) to HarmonyOS NEXT.
It includes complete cross-compilation scripts, over 20 patches for OHOS musl, HAP project
templates, HNP packaging recipes, and debugging tools.

> 💡 **About This Project**
> This project relies heavily on AI assistance (Vibe Coding) for its completion; even this documentation has been polished with AI help.
> The port is still in its early stages and may contain various pitfalls, so please approach it with an exploratory mindset. Issues and PRs are welcome.

> ⚠️ **Platform Restrictions**
> - Only supports HarmonyOS NEXT-powered HarmonyOS PCs (requires a kernel with a 39-bit address space + LSE/ASIMDDP instruction set)
> - Not yet tested on phones or tablets (HNP support status on non-PC devices is unknown)
> - Due to limitations in the HAP self-signing process, this repository does not provide pre-compiled HAPs

## Table of Contents
- [Current Status](#current-status)
- [Repository Structure](#repository-structure)
- [Pre-Build Preparation](#pre-build-preparation)
- [Build Process](#build-process)
- [Testing and Verification](#testing-and-verification)
- [HAP Integration](#hap-integration)
- [Patch Index](#patch-index)
- [Debugging Tools](#Debugging-Tools)
- [Acknowledgments](#Acknowledgments)
- [License](#License)

## Current Status

| Type              | Status | Notes                                     |
|-------------------|------|----------- -------------------------------|
| musl  / dynamic   | ✅   | 14/14 tests passed                           |
| glibc / dynamic   | ✅   | 14/14 tests passed                           |
| musl  / static    | ⚠️   | Signal handler incompatibility             |
| glibc / static    | ❌   | Known upstream limitation on box64                       |
| Multithreading (pthread)  | ✅   | create/join/mutex all passed                 |
| File I/O           | ✅   | fopen/fread/fstat passed                   |
| signal            | ✅   | sigaction available on dynamic ELF            |
| Floating-point / SIMD       | ✅   | FPU/SSE paths pass                           |
| DynaRec           | ✅   | Enabled, includes ASIMD/AES/CRC32 on Kirin 9010... |

## Repository Structure

```
HarmonyBox/
├── README.md
├── LICENSE                              # MIT
├── .gitignore

Translated with DeepL.com (free version)
