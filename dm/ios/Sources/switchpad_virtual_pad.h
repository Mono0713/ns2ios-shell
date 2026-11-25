#pragma once

#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

typedef struct {
    uint32_t version;
    void (*configure)(void *(*make)(CGRect), void (*reset)(void));
    void (*buttons)(uint64_t, int32_t, int32_t, int32_t, int32_t);
    void (*touches)(const void *, int);
    void *(*menu)(void);
} SwitchPadVirtualPad;

typedef struct {
    uint32_t version;
    void (*adopt)(void);
    void (*player)(int, uint64_t, int32_t, int32_t, int32_t, int32_t);
    void (*slots)(uint32_t, uint32_t);
    void (*clear)(int);
    void (*motion)(int, const float *, const float *, const float *, const float *);
    void (*pause)(int);
    void *(*menu_host)(void);
} SwitchPadShellControls;
