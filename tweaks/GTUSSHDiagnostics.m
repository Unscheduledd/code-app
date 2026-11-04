// GTU Code App SSH transport diagnostic and IPv4-literal resolution fix.
// Reversible: this is only active while this dylib is injected.
// Does not change host identity verification, credentials, server settings,
// SSH algorithms, or private-key handling. Do not inject alongside v1.

#include <arpa/inet.h>
#include <sys/socket.h>
#include <stdio.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

@protocol GTUSSHSession <NSObject>
@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) NSNumber *port;
@property (nonatomic, readonly) NSError *lastError;
@property (nonatomic, readonly) CFSocketRef socket;
- (void *)rawSession;
- (NSArray *)hostIPAddresses;
@end

static BOOL (*connectOriginal)(id, SEL);
static void (*disconnectOriginal)(id, SEL);
static NSArray *(*addressesOriginal)(id, SEL);

static __thread BOOL tracking;
static __thread BOOL usedDirectIPv4;
static __thread NSInteger addressCount;
static __thread BOOL reachedDisconnect;
static __thread BOOL hadSocket;
static __thread BOOL hadNativeSession;
static __thread NSInteger nativeError;
static __thread int socketError;
static __thread BOOL socketErrorKnown;
static __thread char nativeMessage[512];

static NSArray *addressesPatched(id obj, SEL selector) {
    NSString *host = [(id<GTUSSHSession>)obj host];
    struct sockaddr_in ipv4 = {0};
    if (host && inet_pton(AF_INET, host.UTF8String, &ipv4.sin_addr) == 1) {
        ipv4.sin_len = sizeof(ipv4);
        ipv4.sin_family = AF_INET;
        ipv4.sin_port = htons((uint16_t)[[(id<GTUSSHSession>)obj port] intValue]);
        NSArray *addresses = @[[NSData dataWithBytes:&ipv4 length:sizeof(ipv4)]];
        if (tracking) {
            usedDirectIPv4 = YES;
            addressCount = 1;
        }
        return addresses;
    }
    NSArray *addresses = addressesOriginal(obj, selector);
    if (tracking) addressCount = addresses ? (NSInteger)addresses.count : -1;
    return addresses;
}

static void disconnectPatched(id obj, SEL selector) {
    if (tracking) {
        reachedDisconnect = YES;
        hadNativeSession = [(id<GTUSSHSession>)obj rawSession] != NULL;
        CFSocketRef socket = [(id<GTUSSHSession>)obj socket];
        hadSocket = socket != NULL;
        if (socket && CFSocketIsValid(socket)) {
            int fd = CFSocketGetNative(socket);
            if (fd >= 0) {
                int soerr = 0;
                socklen_t size = sizeof(soerr);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &size) == 0) {
                    socketErrorKnown = YES;
                    socketError = soerr;
                }
            }
        }
        if (hadNativeSession) {
            NSError *error = [(id<GTUSSHSession>)obj lastError];
            if ([error isKindOfClass:[NSError class]] && error.code != 0) {
                nativeError = error.code;
                snprintf(nativeMessage, sizeof(nativeMessage), "%s",
                         (error.localizedDescription ?: @"No details").UTF8String);
            }
        }
    }
    disconnectOriginal(obj, selector);
}

static void displayResult(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
            if (window) break;
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) {
            controller = controller.presentedViewController;
        }
        if (!controller) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"GTU SSH transport details (v2)"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy Details"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                UIPasteboard.generalPasteboard.string = message;
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleCancel handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL connectPatched(id obj, SEL selector) {
    tracking = YES;
    usedDirectIPv4 = NO;
    addressCount = -2;
    reachedDisconnect = NO;
    hadSocket = NO;
    hadNativeSession = NO;
    nativeError = 0;
    socketErrorKnown = NO;
    socketError = 0;
    nativeMessage[0] = '\0';

    BOOL connected = connectOriginal(obj, selector);
    tracking = NO;

    if (!connected) {
        NSString *stage = @"Unknown (no disconnect callback)";
        if (reachedDisconnect && hadNativeSession) {
            stage = @"SSH session initialization / handshake";
        } else if (reachedDisconnect && hadSocket) {
            stage = @"TCP socket connection / setup";
        } else if (reachedDisconnect) {
            stage = @"Address lookup / socket setup";
        } else if (addressCount >= 0) {
            stage = @"Before socket setup";
        }
        NSMutableString *detail = [NSMutableString stringWithFormat:
            @"Stage: %@\nNumeric IPv4 resolver bypass: %@\nResolved addresses: %ld\nSocket created: %@\nSSH session allocated: %@",
            stage, usedDirectIPv4 ? @"YES" : @"NO", (long)addressCount,
            hadSocket ? @"YES" : @"NO", hadNativeSession ? @"YES" : @"NO"];
        if (socketErrorKnown) {
            [detail appendFormat:@"\nSocket SO_ERROR: %d (%s)",
                socketError, strerror(socketError)];
        }
        if (nativeError) {
            [detail appendFormat:@"\nlibssh2 error %ld: %s",
                (long)nativeError, nativeMessage];
        } else {
            [detail appendString:@"\nNo libssh2 error exposed"];
        }
        displayResult(detail);
    }
    return connected;
}

__attribute__((constructor))
static void installGTUSSHTransport(void) {
    @autoreleasepool {
        Class klass = NSClassFromString(@"NMSSHSession");
        Method connect = class_getInstanceMethod(klass, @selector(connect));
        Method disconnect = class_getInstanceMethod(klass, @selector(disconnect));
        Method addresses = class_getInstanceMethod(klass, @selector(hostIPAddresses));
        if (!klass || !connect || !disconnect || !addresses) {
            NSLog(@"GTU SSH v2: NMSSHSession methods unavailable");
            return;
        }
        connectOriginal = (BOOL (*)(id, SEL))method_getImplementation(connect);
        disconnectOriginal = (void (*)(id, SEL))method_getImplementation(disconnect);
        addressesOriginal = (NSArray *(*)(id, SEL))method_getImplementation(addresses);
        method_setImplementation(addresses, (IMP)addressesPatched);
        method_setImplementation(disconnect, (IMP)disconnectPatched);
        method_setImplementation(connect, (IMP)connectPatched);
        NSLog(@"GTU SSH v2: numeric IPv4 handling and transport details installed");
    }
}
