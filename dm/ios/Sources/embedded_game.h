#pragma once

#import <UIKit/UIKit.h>
#include <stdint.h>

// Start a signed engine embedded in the app bundle. Returns an error to display if it cannot start.
NSString *embedded_game_start(NSString *title, NSString *romfs, NSString *shaders, UIWindow *window);
BOOL embedded_game_focus(int event);
BOOL embedded_game_virtual_active(void);
BOOL embedded_game_buttons(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
BOOL embedded_game_touches(const void *points, int count);
BOOL embedded_game_show_menu(UIView *view, CGPoint anchor);
