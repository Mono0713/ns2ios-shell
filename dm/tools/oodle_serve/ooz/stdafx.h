// Portable replacement for ooz's stdafx.h (the original pulls in <Windows.h> and MSVC-only names). Not part of upstream ooz:
// it gives kraken.cpp / lzna.cpp / bitknit.cpp the MSVC intrinsics they use, so the same three files build with MSVC on
// Windows (the packer's oodle_serve.exe) and with GCC or Clang on Linux and macOS (tests).
#pragma once
#define _CRT_SECURE_NO_WARNINGS 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <assert.h>

typedef unsigned char byte;
typedef unsigned char uint8;
typedef unsigned int uint32;
typedef unsigned long long uint64;
typedef signed long long int64;
typedef signed int int32;
typedef unsigned short uint16;
typedef signed short int16;
typedef unsigned int uint;

#if defined(_MSC_VER)
#include <intrin.h>
#pragma warning (disable: 4244 4267 4146)
#else
#include <x86intrin.h>
#define __forceinline inline __attribute__((always_inline))
#define __int64 long long
typedef unsigned long DWORD;
static inline unsigned char _BitScanReverse(unsigned long *index, uint32 x) { if (!x) return 0; *index = 31 - __builtin_clz(x); return 1; }
static inline unsigned char _BitScanForward(unsigned long *index, uint32 x) { if (!x) return 0; *index = __builtin_ctz(x); return 1; }
#ifndef _rotl
static inline uint32 _rotl(uint32 x, int n) { n &= 31; return n ? (x << n) | (x >> (32 - n)) : x; }
#endif
#define _byteswap_ushort __builtin_bswap16
#define _byteswap_ulong __builtin_bswap32
#define _byteswap_uint64 __builtin_bswap64
#endif
