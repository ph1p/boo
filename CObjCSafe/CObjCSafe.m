#import "CObjCSafe.h"
#import <os/log.h>

static os_log_t BooSafeLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.boo.app", "text-drawing");
    });
    return log;
}

static void BooLogException(const char *call, NSString *string, NSException *exception) {
    os_log_error(BooSafeLog(), "%{public}s threw %{public}@: %{public}@ (length %lu)", call,
                 exception.name, exception.reason, (unsigned long)string.length);
}

BOOL BooSafeDrawString(NSString *string, NSPoint point, NSDictionary<NSAttributedStringKey, id> *attributes) {
    @try {
        [string drawAtPoint:point withAttributes:attributes];
        return YES;
    } @catch (NSException *exception) {
        BooLogException("drawAtPoint:withAttributes:", string, exception);
        return NO;
    }
}

NSSize BooSafeStringSize(NSString *string, NSDictionary<NSAttributedStringKey, id> *attributes) {
    @try {
        return [string sizeWithAttributes:attributes];
    } @catch (NSException *exception) {
        BooLogException("sizeWithAttributes:", string, exception);
        return NSZeroSize;
    }
}
