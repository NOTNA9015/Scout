#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Two small hooks, each calling the original: a view controller appearing (so Scout can add its
// pill to Your Library and its Compile button to Local Files), and a shake (so Scout opens from
// anywhere).

static void (*originalDidAppear)(id, SEL, BOOL);
static void (*originalMotionEnded)(id, SEL, UIEventSubtype, UIEvent *);

static void scoutDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    originalDidAppear(self, _cmd, animated);
    Class entry = NSClassFromString(@"ScoutEntry");
    SEL attach = NSSelectorFromString(@"attachTo:");
    if ([entry respondsToSelector:attach]) ((void (*)(id, SEL, id))objc_msgSend)(entry, attach, self);
}

static void scoutMotionEnded(UIWindow *self, SEL _cmd, UIEventSubtype motion, UIEvent *event) {
    if (originalMotionEnded) originalMotionEnded(self, _cmd, motion, event);
    if (motion != UIEventSubtypeMotionShake) return;
    Class entry = NSClassFromString(@"ScoutEntry");
    SEL present = NSSelectorFromString(@"presentFrom:");
    if ([entry respondsToSelector:present]) ((void (*)(id, SEL, id))objc_msgSend)(entry, present, self);
}

static void swap(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    // Add on the class itself first so a superclass's implementation is never replaced for everyone.
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) *original = method_getImplementation(method);
    else *original = method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void ScoutLoad(void) {
    NSBundle *main = NSBundle.mainBundle;
    // package.py stamps ScoutVersion into the patched Spotify; the bundle id may be changed by the signer.
    BOOL spotify = [main objectForInfoDictionaryKey:@"ScoutVersion"] != nil;
    if (!spotify && ![main objectForInfoDictionaryKey:@"ScoutHost"]) return;
    // Inside Spotify only: note Spotify's service transport for the playlist step.
    if (spotify) {
        Class transport = NSClassFromString(@"SCSpotifyTransport");
        if ([transport respondsToSelector:@selector(install)]) ((void (*)(id, SEL))objc_msgSend)(transport, @selector(install));
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        Class entry = NSClassFromString(@"ScoutEntry");
        if ([entry respondsToSelector:@selector(start)]) ((void (*)(id, SEL))objc_msgSend)(entry, @selector(start));
    });
    swap(UIViewController.class, @selector(viewDidAppear:), (IMP)scoutDidAppear, (IMP *)&originalDidAppear);
    swap(UIWindow.class, @selector(motionEnded:withEvent:), (IMP)scoutMotionEnded, (IMP *)&originalMotionEnded);
}
