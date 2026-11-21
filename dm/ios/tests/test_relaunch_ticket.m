#include "relaunch_ticket.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        assert([fm createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSURL *ticket = [root URLByAppendingPathComponent:@"relaunch.txt"];
        assert(dm_take_relaunch_ticket(ticket) == 0);

        assert(dm_write_relaunch_ticket(ticket, NULL));
        NSTimeInterval issued = dm_take_relaunch_ticket(ticket);
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        assert(dm_relaunch_allowed(issued, now, NO));
        assert(!dm_relaunch_allowed(issued, now, YES));
        assert(!dm_relaunch_allowed(issued, issued + 31, NO));
        assert(!dm_relaunch_allowed(issued, issued - 1, NO));
        assert(dm_take_relaunch_ticket(ticket) == 0);

        assert(dm_write_relaunch_ticket(ticket, NULL));
        NSDate *old = [NSDate dateWithTimeIntervalSinceNow:-300];
        assert([fm setAttributes:@{NSFileModificationDate: old} ofItemAtPath:ticket.path error:NULL]);
        assert(!dm_relaunch_allowed(dm_take_relaunch_ticket(ticket), now, NO));

        assert([@"change games\n" writeToURL:ticket atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        assert(dm_take_relaunch_ticket(ticket) == 0);
        assert(![fm fileExistsAtPath:ticket.path]);
        assert([fm removeItemAtURL:root error:NULL]);
        puts("Relaunch ticket: fresh, active process, expired, consumed and legacy cases passed");
    }
}
