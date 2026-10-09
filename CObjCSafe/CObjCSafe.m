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

/// CoreText copies the attribute dictionary with `copyItems:YES`. If a value's `-copy`
/// returns nil, it throws inside C++ frames that `@try` cannot unwind through, and the
/// app aborts. Doing the same copy here first, where a throw is still catchable, catches
/// that case. Keys whose value fails to copy are dropped and logged.
static NSDictionary<NSAttributedStringKey, id> *BooCopyableAttributes(NSDictionary<NSAttributedStringKey, id> *attributes) {
    NSMutableDictionary<NSAttributedStringKey, id> *sanitized = nil;
    for (NSAttributedStringKey key in attributes) {
        id value = attributes[key];
        id copied = nil;
        @try {
            copied = [value conformsToProtocol:@protocol(NSCopying)] ? [value copy] : value;
        } @catch (NSException *exception) {
            copied = nil;
        }
        if (copied == nil) {
            os_log_error(BooSafeLog(), "dropping attribute %{public}@: %{public}@ copied to nil", key,
                         NSStringFromClass([value class]));
            if (sanitized == nil) sanitized = [attributes mutableCopy];
            [sanitized removeObjectForKey:key];
        }
    }
    return sanitized ?: attributes;
}

BOOL BooSafeDrawString(NSString *string, NSPoint point, NSDictionary<NSAttributedStringKey, id> *attributes) {
    @try {
        [string drawAtPoint:point withAttributes:BooCopyableAttributes(attributes)];
        return YES;
    } @catch (NSException *exception) {
        BooLogException("drawAtPoint:withAttributes:", string, exception);
        return NO;
    }
}

NSSize BooSafeStringSize(NSString *string, NSDictionary<NSAttributedStringKey, id> *attributes) {
    @try {
        return [string sizeWithAttributes:BooCopyableAttributes(attributes)];
    } @catch (NSException *exception) {
        BooLogException("sizeWithAttributes:", string, exception);
        return NSZeroSize;
    }
}
