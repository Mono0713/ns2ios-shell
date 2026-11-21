#pragma once

#import <Foundation/Foundation.h>

static inline NSURL *dm_relaunch_ticket_url(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@"relaunch.txt" isDirectory:NO];
}

static inline BOOL dm_write_relaunch_ticket(NSURL *url, NSError **error) {
    return [@"switchpad-change-game-v1\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
}

// Read once at process startup. Discard old markers and malformed tickets as well.
static inline NSTimeInterval dm_take_relaunch_ticket(NSURL *url) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *marker = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    NSDate *date = [fm attributesOfItemAtPath:url.path error:NULL][NSFileModificationDate];
    if (![fm removeItemAtURL:url error:NULL] || ![marker isEqualToString:@"switchpad-change-game-v1\n"]) return 0;
    return date.timeIntervalSince1970;
}

static inline BOOL dm_relaunch_allowed(NSTimeInterval issued, NSTimeInterval now, BOOL wasActive) {
    return !wasActive && issued > 0 && issued <= now && now - issued <= 30;
}
