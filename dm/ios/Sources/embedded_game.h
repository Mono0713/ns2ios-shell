#pragma once

#import <UIKit/UIKit.h>

// Start a signed engine embedded in the app bundle. Returns an error to display if it cannot start.
NSString *embedded_game_start(NSString *title, NSString *romfs, NSString *shaders, UIWindow *window);
BOOL embedded_game_focus(int event);
