#ifndef COBJCSAFE_H
#define COBJCSAFE_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch Objective-C exceptions, and letting one unwind through Swift frames
/// is undefined behavior, so the `@try` has to sit directly around the AppKit call.
/// These wrap the NSString drawing calls whose CoreText internals have been seen to
/// throw (`attempt to insert nil object` from TAttributes::ApplyFont during font
/// fallback): the text is skipped for that frame instead of terminating the app.

/// `-[NSString drawAtPoint:withAttributes:]`; returns NO if AppKit threw.
BOOL BooSafeDrawString(NSString *string, NSPoint point, NSDictionary<NSAttributedStringKey, id> *attributes);

/// `-[NSString sizeWithAttributes:]`; returns NSZeroSize if AppKit threw.
NSSize BooSafeStringSize(NSString *string, NSDictionary<NSAttributedStringKey, id> *attributes);

NS_ASSUME_NONNULL_END

#endif
