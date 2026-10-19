#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Small hooks, each calling the original: a view controller appearing (so Scout can add its
// button to Your Library's header), a shake (so Scout opens from anywhere), and labels and image
// views being filled (so the playlists Scout made from albums are shown as albums).

static void (*originalDidAppear)(id, SEL, BOOL);
static void (*originalMotionEnded)(id, SEL, UIEventSubtype, UIEvent *);
static void (*originalSetText)(id, SEL, NSString *);
static void (*originalSetAttributedText)(id, SEL, NSAttributedString *);
static void (*originalSetImage)(id, SEL, UIImage *);
static Class albumDisplay;

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

static void scoutLabelChanged(UILabel *label) {
    if (albumDisplay && NSThread.isMainThread) ((void (*)(id, SEL, id))objc_msgSend)(albumDisplay, @selector(labelChanged:), label);
}
static void scoutSetText(UILabel *self, SEL _cmd, NSString *text) {
    originalSetText(self, _cmd, text);
    scoutLabelChanged(self);
}
static void scoutSetAttributedText(UILabel *self, SEL _cmd, NSAttributedString *text) {
    originalSetAttributedText(self, _cmd, text);
    scoutLabelChanged(self);
}
static void scoutSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    if (albumDisplay && NSThread.isMainThread) image = ((UIImage *(*)(id, SEL, id, id))objc_msgSend)(albumDisplay, @selector(imageFor:proposed:), self, image);
    originalSetImage(self, _cmd, image);
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
        Class display = NSClassFromString(@"ScoutAlbumDisplay");
        if ([display respondsToSelector:@selector(labelChanged:)] && [display respondsToSelector:@selector(imageFor:proposed:)]) {
            swap(UILabel.class, @selector(setText:), (IMP)scoutSetText, (IMP *)&originalSetText);
            swap(UILabel.class, @selector(setAttributedText:), (IMP)scoutSetAttributedText, (IMP *)&originalSetAttributedText);
            swap(UIImageView.class, @selector(setImage:), (IMP)scoutSetImage, (IMP *)&originalSetImage);
            albumDisplay = display;
        }
    });
    swap(UIViewController.class, @selector(viewDidAppear:), (IMP)scoutDidAppear, (IMP *)&originalDidAppear);
    swap(UIWindow.class, @selector(motionEnded:withEvent:), (IMP)scoutMotionEnded, (IMP *)&originalMotionEnded);
}
