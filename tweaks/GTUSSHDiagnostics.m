// A small, reversible diagnostic tweak for the user's own Code App build.
// Preserve NMSSH's libssh2 error before NMSSH disconnects and frees its session.
// Does not modify host-key validation, cryptographic algorithms, authentication,
// stored credentials, server configuration, or app extension behavior.

#include <stdio.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static BOOL (*originalConnect)(id, SEL) = NULL;
static void (*originalDisconnect)(id, SEL) = NULL;
static __thread BOOL recordingConnection = NO;
static __thread NSInteger lastCode = 0;
static __thread char lastMessage[512];

static void captureLastError(id session) {
    if (!recordingConnection) return;
    NSError *error = [session lastError];
    if (![error isKindOfClass:[NSError class]] || error.code == 0) return;
    lastCode = error.code;
    NSString *description = error.localizedDescription ?: @"No native error description";
    snprintf(lastMessage, sizeof(lastMessage), "%s", description.UTF8String ?: "");
}

static void showError(NSInteger code, NSString *description) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        UIWindow *window = nil;
        for (UIWindow *candidate in app.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) {
            controller = controller.presentedViewController;
        }
        if (!controller) return;
        NSString *details = code != 0
            ? [NSString stringWithFormat:@"libssh2 error %ld: %@", (long)code, description]
            : @"No libssh2 error was available. The TCP socket or SSH handshake failed before authentication.";
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Code App SSH connection details"
            message:details
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static void patchedDisconnect(id self, SEL cmd) {
    captureLastError(self);
    originalDisconnect(self, cmd);
}

static BOOL patchedConnect(id self, SEL cmd) {
    lastCode = 0;
    lastMessage[0] = '\0';
    recordingConnection = YES;
    BOOL connected = originalConnect(self, cmd);
    recordingConnection = NO;
    if (!connected) {
        // Preserve only the native error type/code/message. Never read key data.
        NSString *details = lastMessage[0]
            ? [NSString stringWithUTF8String:lastMessage]
            : @"The library did not return an error message";
        showError(lastCode, details);
    }
    return connected;
}

__attribute__((constructor))
static void installCodeSSHDiagnostics(void) {
    @autoreleasepool {
        Class sessionClass = NSClassFromString(@"NMSSHSession");
        if (!sessionClass) {
            NSLog(@"GTU SSH diagnostics: NMSSHSession is not present");
            return;
        }
        Method connect = class_getInstanceMethod(sessionClass, @selector(connect));
        Method disconnect = class_getInstanceMethod(sessionClass, @selector(disconnect));
        if (!connect || !disconnect) {
            NSLog(@"GTU SSH diagnostics: NMSSH methods are unavailable");
            return;
        }
        originalDisconnect = (void (*)(id, SEL))method_getImplementation(disconnect);
        originalConnect = (BOOL (*)(id, SEL))method_getImplementation(connect);
        method_setImplementation(disconnect, (IMP)patchedDisconnect);
        method_setImplementation(connect, (IMP)patchedConnect);
        NSLog(@"GTU SSH diagnostics installed (no authentication changes)");
    }
}
