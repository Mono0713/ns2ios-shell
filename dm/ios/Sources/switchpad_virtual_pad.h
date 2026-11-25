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
