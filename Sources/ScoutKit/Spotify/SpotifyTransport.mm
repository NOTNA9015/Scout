#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Scout talks to Spotify's own internal services (local files, playlists) the way Spotify's code
// does: through the Esperanto transport object Spotify already has. Spotify hands that object out
// from -[EsperantoServiceImpl provideEsperantoTransport] (spoti.pw picks it up the same way); the
// hooks below only note the object and call straight through, nothing is changed. The transport's
// callSingle:method:payload:onResponse: is @48@0:8@16@24@32@?40 in Spotify 9.1.90, returning an
// SPTEsperantoLifetime that is kept until the answer arrives.

static id SCTransport;
static __weak id SCService;
static BOOL SCInstalled;
static SEL SCCallSingle;

static BOOL SCUsable(id object) { return object && [object respondsToSelector:SCCallSingle]; }

/// -provideEsperantoTransport on Spotify's Esperanto service: note the service and what it returns.
static void SCHookProvider(void) {
    Class type = objc_getClass("_TtC23Esperanto_EsperantoImpl20EsperantoServiceImpl");
    SEL selector = NSSelectorFromString(@"provideEsperantoTransport");
    Method method = type ? class_getInstanceMethod(type, selector) : NULL;
    if (!method || strncmp(method_getTypeEncoding(method), "@16@0:8", 7) != 0) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^id(id service) {
        id transport = ((id (*)(id, SEL))original)(service, selector);
        SCService = service;
        if (SCUsable(transport)) SCTransport = transport;
        return transport;
    });
    // Add on the class itself if the method is inherited, so no other class is affected.
    if (!class_addMethod(type, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
}

/// A second way in: the transport classes themselves, noted the first time any call goes through.
static void SCHookTransport(Class type, SEL selector) {
    Method method = type ? class_getInstanceMethod(type, selector) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "@48@0:8@16@24@32@?40") != 0) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^id(id object, NSString *service, NSString *name, NSData *payload, id onResponse) {
        if (!SCTransport) SCTransport = object;
        return ((id (*)(id, SEL, id, id, id, id))original)(object, selector, service, name, payload, onResponse);
    });
    if (!class_addMethod(type, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
}

/// One line per call into Spotify, written to disk before the call is made, so that if Spotify
/// ever crashes on one, Files → On My iPhone → Spotify → "Scout playlist log.txt" shows which.
static void SCLog(NSString *line) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file = [documents URLByAppendingPathComponent:@"Scout playlist log.txt"];
    NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSData *data = [[NSString stringWithFormat:@"%@  %@\n", [format stringFromDate:NSDate.date], line] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    if (!attributes || [attributes fileSize] > 200000) { [data writeToURL:file atomically:YES]; return; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:nil];
    [handle seekToEndOfFile]; [handle writeData:data]; [handle synchronizeFile]; [handle closeFile];
}

@interface SCSpotifyTransport : NSObject
+ (void)install;
+ (BOOL)isReady;
+ (void)log:(NSString *)line;
+ (void)useTransport:(id)transport;
+ (void)request:(NSString *)service method:(NSString *)method data:(NSData *)data completion:(void (^)(NSData *, NSString *))completion;
@end

@implementation SCSpotifyTransport
+ (void)install {
    if (SCInstalled) return;
    SCInstalled = YES;
    SCCallSingle = NSSelectorFromString(@"callSingle:method:payload:onResponse:");
    SCHookProvider();
    for (NSString *name in @[@"SPTEsperantoTransportBridgeImpl", @"SPTEsperantoCosmosTransport"]) {
        SCHookTransport(NSClassFromString(name), SCCallSingle);
    }
}
/// The noted transport, or a fresh one from the noted service.
+ (id)transport {
    if (SCUsable(SCTransport)) return SCTransport;
    id service = SCService;
    SEL provide = NSSelectorFromString(@"provideEsperantoTransport");
    if (service && [service respondsToSelector:provide]) {
        id transport = ((id (*)(id, SEL))objc_msgSend)(service, provide);
        if (SCUsable(transport)) SCTransport = transport;
    }
    return SCUsable(SCTransport) ? SCTransport : nil;
}
+ (BOOL)isReady { return [self transport] != nil; }
+ (void)log:(NSString *)line { SCLog(line); }
/// Tests only: a stand-in transport that answers later, like Spotify's.
+ (void)useTransport:(id)transport { SCCallSingle = NSSelectorFromString(@"callSingle:method:payload:onResponse:"); SCTransport = transport; }
+ (void)request:(NSString *)service method:(NSString *)method data:(NSData *)data completion:(void (^)(NSData *, NSString *))completion {
    id transport = [self transport];
    if (!transport) { completion(nil, @"Spotify's services aren't ready yet. Open Local Files in Spotify and tap Compile pending playlists again."); return; }
    NSObject *lock = [NSObject new];
    __block BOOL done = NO;
    __block id handle;
    void (^finish)(NSData *, NSString *) = ^(NSData *response, NSString *error) {
        @synchronized (lock) { if (done) return; done = YES; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(response, error); handle = nil; });
    };
    // As spoti.pw does: a void block, and an answer that isn't NSData counts as an empty one.
    void (^onResponse)(id) = ^(id response) {
        finish([response isKindOfClass:NSData.class] ? response : [NSData data], nil);
    };
    NSString *call = [NSString stringWithFormat:@"%@ %@ (%lu bytes) via %@", [service componentsSeparatedByString:@"."].lastObject, method,
                      (unsigned long)data.length, NSStringFromClass(object_getClass(transport))];
    SCLog([@"call " stringByAppendingString:call]);
    void (^logged)(id) = ^(id response) {
        SCLog([NSString stringWithFormat:@"answer %@: %@", call, [response isKindOfClass:NSData.class] ? [NSString stringWithFormat:@"%lu bytes", (unsigned long)[response length]] : NSStringFromClass([response class])]);
        onResponse(response);
    };
    @try {
        handle = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(transport, SCCallSingle, service, method, data ?: [NSData data], logged);
    } @catch (NSException *exception) {
        SCLog([NSString stringWithFormat:@"exception %@: %@", call, exception.reason ?: exception.name]);
        finish(nil, [NSString stringWithFormat:@"Spotify refused the request (%@).", exception.reason ?: exception.name]);
        return;
    } @catch (...) {
        SCLog([@"error " stringByAppendingString:call]);
        finish(nil, @"Spotify refused the request.");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @synchronized (lock) { if (done) return; }
        SEL cancel = NSSelectorFromString(@"cancel");
        if (handle && class_getInstanceMethod(object_getClass(handle), cancel)) ((void (*)(id, SEL))objc_msgSend)(handle, cancel);
        finish(nil, @"Spotify didn't answer in time.");
    });
}
@end
