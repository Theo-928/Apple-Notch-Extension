// MediaBridge — a tiny dylib that is loaded by /usr/bin/perl (an Apple platform
// binary) so it can talk to the private MediaRemote framework. Since macOS 15.4
// MediaRemote refuses now-playing data to third-party processes, but it still
// serves Apple-signed ones. This avoids needing Automation (AppleScript) or
// Accessibility permission to read and control "Now Playing" for any app.
//
// Output: one JSON object per line on stdout.
// Entry points are installed as Perl XSUBs, so they receive (PerlInterpreter*, CV*)
// which we ignore.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static void *gMR;
static MRGetInfoFn gGetInfo;
static MRGetIsPlayingFn gGetIsPlaying;
static MRGetPIDFn gGetPID;
static MRRegisterFn gRegister;
static MRSendCommandFn gSend;
static MRSetElapsedFn gSetElapsed;

static BOOL loadMR(void) {
    if (gMR) return YES;
    gMR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!gMR) return NO;
    gGetInfo = (MRGetInfoFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingInfo");
    gGetIsPlaying = (MRGetIsPlayingFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetPID = (MRGetPIDFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingApplicationPID");
    gRegister = (MRRegisterFn)dlsym(gMR, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gSend = (MRSendCommandFn)dlsym(gMR, "MRMediaRemoteSendCommand");
    gSetElapsed = (MRSetElapsedFn)dlsym(gMR, "MRMediaRemoteSetElapsedTime");
    return gGetInfo != NULL;
}

static NSString *constant(const char *sym, NSString *fallback) {
    CFStringRef *p = (CFStringRef *)dlsym(gMR, sym);
    return (p && *p) ? (__bridge NSString *)*p : fallback;
}

static void writeLine(NSDictionary *obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emitNowPlaying(void) {
    gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"type"] = @"nowPlaying";
        id v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"]) && [v isKindOfClass:NSString.class]) out[@"title"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"]) && [v isKindOfClass:NSString.class]) out[@"artist"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) && [v isKindOfClass:NSString.class]) out[@"album"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"]) && [v isKindOfClass:NSNumber.class]) out[@"duration"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) && [v isKindOfClass:NSNumber.class]) out[@"elapsed"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) && [v isKindOfClass:NSNumber.class]) out[@"rate"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]) && [v isKindOfClass:NSDate.class])
            out[@"timestamp"] = @([(NSDate *)v timeIntervalSince1970]);
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"]) && [v isKindOfClass:NSData.class] && [(NSData *)v length] > 0)
            out[@"artwork"] = [(NSData *)v base64EncodedStringWithOptions:0];

        void (^finish)(void) = ^{
            if (gGetPID) {
                gGetPID(dispatch_get_main_queue(), ^(int pid) {
                    out[@"pid"] = @(pid);
                    writeLine(out);
                });
            } else {
                writeLine(out);
            }
        };
        if (gGetIsPlaying) {
            gGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                out[@"playing"] = @(playing ? YES : NO);
                finish();
            });
        } else {
            finish();
        }
    });
}

__attribute__((visibility("default")))
void notchling_stream(void *perl, void *cv) {
    (void)perl; (void)cv;
    @autoreleasepool {
        if (!loadMR()) { writeLine(@{@"type": @"error", @"message": @"MediaRemote unavailable"}); exit(1); }
        if (gRegister) gRegister(dispatch_get_main_queue());
        NSArray *names = @[
            constant("kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            constant("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            constant("kMRMediaRemoteNowPlayingApplicationDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                (void)note;
                emitNowPlaying();
            }];
        }
        writeLine(@{@"type": @"ready"});
        emitNowPlaying();
        // Exit when the parent app goes away (stdin closes).
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char buf[64];
            while (fread(buf, 1, sizeof buf, stdin) > 0) {}
            exit(0);
        });
        CFRunLoopRun();
    }
    exit(0);
}

// Command is passed in the NOTCHLING_CMD env var: "play", "pause", "toggle",
// "next", "previous", or "seek:<seconds>".
__attribute__((visibility("default")))
void notchling_send(void *perl, void *cv) {
    (void)perl; (void)cv;
    @autoreleasepool {
        if (!loadMR()) exit(1);
        const char *raw = getenv("NOTCHLING_CMD");
        NSString *cmd = raw ? @(raw) : @"";
        int code = -1;
        if ([cmd isEqualToString:@"play"]) code = 0;
        else if ([cmd isEqualToString:@"pause"]) code = 1;
        else if ([cmd isEqualToString:@"toggle"]) code = 2;
        else if ([cmd isEqualToString:@"next"]) code = 4;
        else if ([cmd isEqualToString:@"previous"]) code = 5;
        else if ([cmd hasPrefix:@"seek:"] && gSetElapsed) {
            gSetElapsed([[cmd substringFromIndex:5] doubleValue]);
            // Give the XPC message a moment to leave the process.
            [NSThread sleepForTimeInterval:0.2];
            exit(0);
        }
        if (code >= 0 && gSend) {
            gSend(code, NULL);
            [NSThread sleepForTimeInterval:0.2];
            exit(0);
        }
        exit(2);
    }
}
