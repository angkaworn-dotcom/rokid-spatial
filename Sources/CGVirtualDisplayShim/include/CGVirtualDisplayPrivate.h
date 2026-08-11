//
//  Declarations for CoreGraphics' private virtual-display classes.
//
//  These are real Objective-C classes inside
//  /System/Library/Frameworks/CoreGraphics.framework — verified present on
//  macOS 26.6 — but Apple ships no headers for them. The interfaces below are
//  the community-reverse-engineered shape, as used by DeskPad, BetterDisplay,
//  opendisplay and others. Declaring them lets Swift call the classes; the
//  runtime resolves them from CoreGraphics at load time.
//
//  Private API, with the usual consequences: it can change or vanish in any
//  macOS release, and an app using it cannot ship on the Mac App Store.
//  Everything here is guarded by runtime class lookups on the Swift side so a
//  future macOS that drops these classes degrades to an error message rather
//  than a crash on launch.
//
//  Known limitation: virtual displays are capped at 60 Hz. That caps how often
//  the *desktop contents* change, not how often we redraw — head tracking
//  still renders at the panel's full rate, so motion stays smooth.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) CGFloat refreshRate;
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id _Nullable, id _Nullable);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) NSString *name;
@property(readonly, nonatomic) unsigned int maxPixelsHigh;
@property(readonly, nonatomic) unsigned int maxPixelsWide;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
