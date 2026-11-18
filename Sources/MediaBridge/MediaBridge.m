// MediaBridge — now-playing bridge loaded into /usr/bin/perl.
//
// Since macOS 15.4 mediaremoted only answers processes whose bundle identifier
// starts with "com.apple.". /usr/bin/perl qualifies (com.apple.perl5), so the
// app spawns perl, which loads this dylib through DynaLoader and calls
// `omnihub_media_stream`. The function never returns: it prints one JSON line
// per state change on stdout and executes commands read from stdin
// ("toggle", "play", "pause", "next", "prev", "seek <seconds>",
// "shuffle <mode>", "repeat <mode>", "like", "unlike"; "clients" lists every
// registered player). Which player it shows is decided in PlayerChoice.h:
// music before video, the one just started, and otherwise the shown one for
// as long as it plays.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <libproc.h>
#import "PlayerChoice.h"

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*MRSendCommandFn)(unsigned int, CFDictionaryRef);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRSetElapsedFn)(double);
typedef void *(*MRGetLocalOriginFn)(void);
typedef void (*MRGetSupportedFn)(void *, dispatch_queue_t, void (^)(CFArrayRef));
typedef unsigned int (*MRCommandInfoCommandFn)(void *);
typedef Boolean (*MRCommandInfoEnabledFn)(void *);
typedef CFDictionaryRef (*MRCommandInfoOptionsFn)(void *);
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef CFStringRef (*MRClientBundleFn)(void *);
typedef int (*MRClientPIDFn)(void *);
typedef void *(*MRPlayerPathCreateFn)(void *, void *, void *);
typedef void (*MRInfoForPlayerFn)(void *, Boolean, dispatch_queue_t, void (^)(CFDictionaryRef, void *));
typedef void (*MRSupportedForPlayerFn)(void *, dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*MRSendToPlayerFn)(unsigned int, CFDictionaryRef, void *, unsigned int, dispatch_queue_t, void (^)(id));
typedef void (*MRStateForPlayerFn)(void *, dispatch_queue_t, void (^)(unsigned int));

static MRGetInfoFn getInfo;
static MRGetPIDFn getPID;
static MRGetPlayingFn getPlaying;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;
static MRGetLocalOriginFn getLocalOrigin;
static MRGetSupportedFn getSupported;
static MRCommandInfoCommandFn commandInfoCommand;
static MRCommandInfoEnabledFn commandInfoEnabled;
static MRCommandInfoOptionsFn commandInfoOptions;
static MRGetClientsFn getClients;
static MRClientBundleFn clientBundle;
static MRClientPIDFn clientPID;
static MRPlayerPathCreateFn playerPathCreate;
static MRInfoForPlayerFn infoForPlayer;
static MRStateForPlayerFn stateForPlayer;
static MRSupportedForPlayerFn supportedForPlayer;
static MRSendToPlayerFn sendToPlayer;
typedef void *(*MRPlayerCreateFn)(CFStringRef, CFStringRef);
static MRPlayerCreateFn playerCreate;

static NSString *artworkPath;
static NSString *lastLine;
static NSString *lastArtworkKey;

static void emit(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return;
    lastLine = line;
    fputs(line.UTF8String, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// The player the bridge shows (PlayerChoice.h decides): its pid (0 = none
// yet), the path its info is read from (nil = the system's now-playing app,
// read without a player list) and the path commands are addressed to.
// Commands need the player spelled out: a path with no player resolves to
// the active player of the origin, i.e. the system's now-playing app.
static int shownPID;
static id shownPath;
static id shownCommandPath;
// The shown player does not hold Now Playing (it was at the last poll).
static BOOL shownFollowed;
// The shown player was controlled from OmniHub since it was chosen.
static BOOL shownPinned;
// When each player (pid) was last seen playing; a player playing again
// after this long counts as just started.
static NSMutableDictionary<NSNumber *, NSDate *> *lastPlaying;
static const NSTimeInterval recentPlayWindow = 3;

// Music apps: their Info.plist says so, or they are known not to.
static NSMutableDictionary<NSNumber *, NSNumber *> *musicByPID;
static NSSet<NSString *> *musicBundles;

static BOOL isMusicPlayer(int pid, NSString *bundle) {
    if (bundle.length && [musicBundles containsObject:bundle]) return YES;
    NSNumber *cached = musicByPID[@(pid)];
    if (cached) return cached.boolValue;
    BOOL music = NO;
    char buffer[PROC_PIDPATHINFO_MAXSIZE];
    if (pid > 0 && proc_pidpath(pid, buffer, sizeof buffer) > 0) {
        // The outermost app bundle (a browser helper belongs to the browser).
        NSString *path = [NSString stringWithUTF8String:buffer];
        NSRange app = [path rangeOfString:@".app/"];
        if (app.location != NSNotFound) {
            NSString *plist = [[path substringToIndex:app.location + 4]
                               stringByAppendingPathComponent:@"Contents/Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
            music = [info[@"LSApplicationCategoryType"] isEqual:@"public.app-category.music"];
        }
    }
    musicByPID[@(pid)] = @(music);
    return music;
}

static id commandPathFor(id client) {
    if (!playerCreate) return nil;
    id player = (__bridge_transfer id)playerCreate(CFSTR("MediaRemote-DefaultPlayer"), NULL);
    return (__bridge id)playerPathCreate(getLocalOrigin(), (__bridge void *)client, (__bridge void *)player);
}

/// Item fields from a now-playing info dictionary.
static NSMutableDictionary *payloadFromInfo(NSDictionary *info) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    out[@"title"] = [title isKindOfClass:NSString.class] ? title : @"";
    out[@"artist"] = [artist isKindOfClass:NSString.class] ? artist : @"";
    out[@"album"] = [album isKindOfClass:NSString.class] ? album : @"";
    out[@"rate"] = [rate isKindOfClass:NSNumber.class] ? rate : @0;
    // Position: `elapsed` was true at `timestamp`; the app extrapolates.
    NSNumber *elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    out[@"elapsed"] = [elapsed isKindOfClass:NSNumber.class] ? elapsed : @(-1);
    out[@"duration"] = [duration isKindOfClass:NSNumber.class] ? duration : @0;
    out[@"timestamp"] = [stamp isKindOfClass:NSDate.class] ? @(stamp.timeIntervalSince1970) : @0;
    // Play mode and like state, when the player publishes them
    // (shuffle 1 off / 3 tracks, repeat 1 off / 2 one / 3 all; 0 unknown).
    NSNumber *shuffle = info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"];
    NSNumber *repeat = info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"];
    NSNumber *liked = info[@"kMRMediaRemoteNowPlayingInfoIsLiked"];
    out[@"shuffle"] = [shuffle isKindOfClass:NSNumber.class] ? shuffle : @0;
    out[@"repeat"] = [repeat isKindOfClass:NSNumber.class] ? repeat : @0;
    out[@"liked"] = [liked isKindOfClass:NSNumber.class] ? @(liked.boolValue ? 1 : 0) : @(-1);

    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:NSData.class] && artwork.length > 0 && artworkPath) {
        NSString *key = [NSString stringWithFormat:@"%@|%@|%lu",
                         out[@"title"], out[@"artist"], (unsigned long)artwork.length];
        if (![key isEqualToString:lastArtworkKey]) {
            [artwork writeToFile:artworkPath atomically:YES];
            lastArtworkKey = key;
        }
        out[@"artwork"] = key;
    } else {
        out[@"artwork"] = @"";
    }
    return out;
}

/// Adds pid, playing and the player's enabled commands, then prints.
/// `stateKnown`: `playing` came from the system's playback state. Only
/// without one does the item's rate count: QQ Music leaves the rate at 1
/// when it pauses, so the rate alone would keep a paused song running.
static void finishPayload(NSMutableDictionary *out, int pid, BOOL playing, BOOL stateKnown, id path,
                          BOOL followed, BOOL music) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    out[@"pid"] = @(pid);
    out[@"playing"] = @(stateKnown ? playing : (playing || [out[@"rate"] doubleValue] > 0));
    // 1 = a player other than the system's now-playing app. Commands are
    // addressed to it by name; a browser or video player ignores them until
    // it holds Now Playing itself (music apps take them).
    out[@"followed"] = @(followed ? 1 : 0);
    out[@"music"] = @(music ? 1 : 0);
    // Commands the player registered and has enabled (MediaRemote command
    // numbers). A command missing here is ignored by it.
    void (^commands)(CFArrayRef) = ^(CFArrayRef raw) {
        NSMutableArray *enabled = [NSMutableArray array];
        for (id info in (__bridge NSArray *)raw) {
            void *ref = (__bridge void *)info;
            unsigned int command = commandInfoCommand(ref);
            if (commandInfoEnabled(ref)) [enabled addObject:@(command)];
            if (!commandInfoOptions || (command != 21 && command != 25 && command != 26)) continue;
            // Players built on MPRemoteCommandCenter keep the current mode /
            // like state on the command, not in the item info.
            CFDictionaryRef rawOptions = commandInfoOptions(ref);
            NSDictionary *options = (__bridge NSDictionary *)rawOptions;
            NSNumber *shuffle = options[@"kMRMediaRemoteCommandInfoShuffleMode"];
            NSNumber *repeat = options[@"kMRMediaRemoteCommandInfoRepeatMode"];
            NSNumber *active = options[@"kMRMediaRemoteCommandInfoIsActiveKey"];
            if (command == 26 && [shuffle isKindOfClass:NSNumber.class] && [out[@"shuffle"] intValue] == 0) out[@"shuffle"] = shuffle;
            if (command == 25 && [repeat isKindOfClass:NSNumber.class] && [out[@"repeat"] intValue] == 0) out[@"repeat"] = repeat;
            if (command == 21 && [active isKindOfClass:NSNumber.class] && [out[@"liked"] intValue] < 0) {
                out[@"liked"] = @(active.boolValue ? 1 : 0);
            }
            if (rawOptions) CFRelease(rawOptions);
        }
        [enabled sortUsingSelector:@selector(compare:)];
        out[@"commands"] = enabled;
        emit(out);
    };
    if (!commandInfoCommand || !commandInfoEnabled) { emit(out); return; }
    if (path && supportedForPlayer) {
        supportedForPlayer((__bridge void *)path, queue, commands);
    } else if (!path && getSupported && getLocalOrigin) {
        getSupported(getLocalOrigin(), queue, commands);
    } else {
        emit(out);
    }
}

/// The system's now-playing app.
static void pollMain(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    getInfo(queue, ^(CFDictionaryRef raw) {
        NSMutableDictionary *out = payloadFromInfo((__bridge NSDictionary *)raw);
        if (!getPID) { finishPayload(out, 0, NO, NO, nil, NO, NO); return; }
        getPID(queue, ^(int pid) {
            shownPID = pid;
            BOOL music = isMusicPlayer(pid, nil);
            if (!getPlaying) { finishPayload(out, pid, NO, NO, nil, NO, music); return; }
            getPlaying(queue, ^(Boolean playing) { finishPayload(out, pid, playing, YES, nil, NO, music); });
        });
    });
}

/// One registered player, by its player path: info, pid and state all from
/// that one player, so a poll never mixes two of them.
static void pollPlayer(id path, int pid, int state, BOOL followed, BOOL music) {
    infoForPlayer((__bridge void *)path, YES, dispatch_get_main_queue(), ^(CFDictionaryRef raw, void *unused) {
        finishPayload(payloadFromInfo((__bridge NSDictionary *)raw), pid, state == PlayerStatePlaying,
                      state != PlayerStateUnknown, path, followed, music);
    });
}

/// Shows the system's now-playing app, read without a player list.
static void showSystemPlayer(void) {
    if (shownPath) shownPinned = NO;
    shownPath = nil;
    shownCommandPath = nil;
    shownFollowed = NO;
    pollMain();
}

static void poll(void) {
    if (!getInfo) return;
    if (!getClients || !playerPathCreate || !stateForPlayer || !infoForPlayer || !getPID || !getLocalOrigin || !clientPID) {
        showSystemPlayer();
        return;
    }
    dispatch_queue_t queue = dispatch_get_main_queue();
    getPID(queue, ^(int mainPID) {
        getClients(queue, ^(CFArrayRef raw) {
            NSArray *clients = [(__bridge NSArray *)raw copy];
            if (clients.count < 2) { showSystemPlayer(); return; }
            NSMutableArray *paths = [NSMutableArray array];
            NSMutableArray *pids = [NSMutableArray array];
            NSMutableArray *states = [NSMutableArray array];
            for (id client in clients) {
                id path = (__bridge id)playerPathCreate(getLocalOrigin(), (__bridge void *)client, NULL);
                [paths addObject:path ?: NSNull.null];
                [pids addObject:@(clientPID((__bridge void *)client))];
                [states addObject:@(PlayerStateUnknown)];
            }
            __block NSUInteger pending = clients.count;
            __block BOOL chosen = NO;
            void (^choose)(void) = ^{
                if (chosen) return;
                chosen = YES;
                int count = (int)clients.count;
                int stateList[count];
                bool recent[count], music[count];
                NSDate *now = NSDate.date;
                int mainIndex = -1, shownIndex = -1;
                for (int i = 0; i < count; i++) {
                    int pid = [pids[i] intValue];
                    stateList[i] = paths[i] == NSNull.null ? PlayerStateUnknown : [states[i] intValue];
                    NSDate *seen = lastPlaying[pids[i]];
                    recent[i] = seen && [now timeIntervalSinceDate:seen] < recentPlayWindow;
                    NSString *bundle = clientBundle ? (__bridge NSString *)clientBundle((__bridge void *)clients[i]) : nil;
                    music[i] = isMusicPlayer(pid, bundle);
                    if (pid == mainPID && mainIndex < 0) mainIndex = i;
                    if (shownPID > 0 && pid == shownPID && shownIndex < 0) shownIndex = i;
                }
                int pick = omnihub_choose_player(stateList, recent, music, count, mainIndex, shownIndex, shownPinned);
                for (int i = 0; i < count; i++) {
                    if (stateList[i] == PlayerStatePlaying) lastPlaying[pids[i]] = now;
                }
                if (pick < 0 || paths[pick] == NSNull.null) { showSystemPlayer(); return; }
                int pid = [pids[pick] intValue];
                if (pid != shownPID) shownPinned = NO;
                shownPID = pid;
                shownPath = paths[pick];
                shownCommandPath = commandPathFor(clients[pick]) ?: shownPath;
                shownFollowed = pick != mainIndex;
                pollPlayer(shownPath, pid, stateList[pick], shownFollowed, music[pick]);
            };
            for (NSUInteger i = 0; i < paths.count; i++) {
                if (paths[i] == NSNull.null) { if (--pending == 0) choose(); continue; }
                stateForPlayer((__bridge void *)paths[i], queue, ^(unsigned int state) {
                    states[i] = @(state);
                    if (--pending == 0) choose();
                });
            }
            // Never wait on a player that does not answer.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), queue, choose);
        });
    });
}

/// Sends a command addressed to the shown player by name.
static void sendToShownPath(unsigned int code, NSDictionary *options) {
    if (!sendToPlayer || !shownCommandPath) return;
    sendToPlayer(code, (__bridge CFDictionaryRef)options, (__bridge void *)shownCommandPath, 0,
                 dispatch_get_main_queue(), ^(id result) {});
}

/// Runs `direct` when the shown player holds Now Playing right now, else
/// `addressed`: the system may have handed Now Playing to another player
/// since the last poll, and a plain command would reach that one.
static void ifShownHoldsNowPlaying(void (^direct)(void), void (^addressed)(void)) {
    if (shownFollowed) { addressed(); return; }
    if (!getPID || !shownCommandPath || !sendToPlayer) { direct(); return; }
    getPID(dispatch_get_main_queue(), ^(int pid) {
        if (pid == shownPID) direct(); else addressed();
    });
}

/// Sends a command to the shown player.
static void sendToTarget(unsigned int code, NSDictionary *options) {
    shownPinned = YES;
    ifShownHoldsNowPlaying(^{
        if (sendCommand) sendCommand(code, (__bridge CFDictionaryRef)options);
        else sendToShownPath(code, options);
    }, ^{ sendToShownPath(code, options); });
}

static void handleCommand(NSString *command) {
    // "clients": every app registered with now-playing (diagnostics).
    if ([command isEqualToString:@"clients"]) {
        if (!getClients) { fputs("{\"clients\":null}\n", stdout); fflush(stdout); return; }
        getClients(dispatch_get_main_queue(), ^(CFArrayRef list) {
            NSMutableArray *out = [NSMutableArray array];
            for (id client in (__bridge NSArray *)list) {
                NSString *bundle = clientBundle ? (__bridge NSString *)clientBundle((__bridge void *)client) : nil;
                int pid = clientPID ? clientPID((__bridge void *)client) : 0;
                [out addObject:@{@"bundle": bundle ?: @"", @"pid": @(pid), @"music": @(isMusicPlayer(pid, bundle)),
                                 @"shown": @(pid == shownPID)}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"clients": out} options:0 error:nil];
            fputs([[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String], stdout);
            fputs("\n", stdout);
            fflush(stdout);
        });
        return;
    }
    // "seek <seconds>": jump to an absolute position in the current item.
    if ([command hasPrefix:@"seek "]) {
        double seconds = MAX(0, [[command substringFromIndex:5] doubleValue]);
        NSDictionary *position = @{@"kMRMediaRemoteOptionPlaybackPosition": @(seconds)};
        shownPinned = YES;
        ifShownHoldsNowPlaying(^{
            if (setElapsed) setElapsed(seconds); else sendToShownPath(24, position);
        }, ^{ sendToShownPath(24, position); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ poll(); });
        return;
    }
    if (!sendCommand && !sendToPlayer) return;
    // Play mode: "shuffle 3", "repeat 2"; like / unlike the current item.
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    if (parts.count == 2 && ([parts[0] isEqualToString:@"shuffle"] || [parts[0] isEqualToString:@"repeat"])) {
        BOOL shuffle = [parts[0] isEqualToString:@"shuffle"];
        NSDictionary *options = @{(shuffle ? @"kMRMediaRemoteOptionShuffleMode" : @"kMRMediaRemoteOptionRepeatMode"):
                                      @([parts[1] intValue])};
        sendToTarget(shuffle ? 26 : 25, options);
    } else if ([command isEqualToString:@"like"] || [command isEqualToString:@"unlike"]) {
        NSDictionary *options = @{@"kMRMediaRemoteOptionIsNegative": @([command isEqualToString:@"unlike"])};
        sendToTarget(21, options);
    } else {
        goto plain;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll(); });
    return;
plain:;
    unsigned int code;
    if ([command isEqualToString:@"play"]) code = 0;
    else if ([command isEqualToString:@"pause"]) code = 1;
    else if ([command isEqualToString:@"toggle"]) code = 2;
    else if ([command isEqualToString:@"next"]) code = 4;
    else if ([command isEqualToString:@"prev"]) code = 5;
    else return;
    sendToTarget(code, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll(); });
}

__attribute__((visibility("default")))
void omnihub_media_stream(void) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!handle) {
            fputs("{\"error\":\"dlopen\"}\n", stdout);
            fflush(stdout);
            exit(2);
        }
        getInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        getPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        getPlaying = (MRGetPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        setElapsed = (MRSetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        getLocalOrigin = (MRGetLocalOriginFn)dlsym(handle, "MRMediaRemoteGetLocalOrigin");
        getSupported = (MRGetSupportedFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForOrigin");
        commandInfoCommand = (MRCommandInfoCommandFn)dlsym(handle, "MRMediaRemoteCommandInfoGetCommand");
        commandInfoEnabled = (MRCommandInfoEnabledFn)dlsym(handle, "MRMediaRemoteCommandInfoGetEnabled");
        commandInfoOptions = (MRCommandInfoOptionsFn)dlsym(handle, "MRMediaRemoteCommandInfoCopyOptions");
        MRRegisterFn registerFn = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        getClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
        clientBundle = (MRClientBundleFn)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
        clientPID = (MRClientPIDFn)dlsym(handle, "MRNowPlayingClientGetProcessIdentifier");
        playerPathCreate = (MRPlayerPathCreateFn)dlsym(handle, "MRNowPlayingPlayerPathCreate");
        infoForPlayer = (MRInfoForPlayerFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
        stateForPlayer = (MRStateForPlayerFn)dlsym(handle, "MRMediaRemoteGetPlaybackStateForPlayer");
        supportedForPlayer = (MRSupportedForPlayerFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForPlayer");
        sendToPlayer = (MRSendToPlayerFn)dlsym(handle, "MRMediaRemoteSendCommandToPlayer");
        playerCreate = (MRPlayerCreateFn)dlsym(handle, "MRNowPlayingPlayerCreate");

        lastPlaying = [NSMutableDictionary dictionary];
        musicByPID = [NSMutableDictionary dictionary];
        // Music apps whose Info.plist names another category (or none).
        musicBundles = [NSSet setWithArray:@[@"com.soda.music", @"com.netease.163music", @"com.tencent.QQMusicMac",
                                             @"com.spotify.client", @"com.apple.Music", @"com.apple.iTunes",
                                             @"com.kugou.mac.Music", @"com.kuwo.KuwoMusic"]];
        const char *path = getenv("OMNIHUB_ARTWORK_PATH");
        if (path) artworkPath = [NSString stringWithUTF8String:path];

        if (registerFn) registerFn(dispatch_get_main_queue());
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteSupportedCommandsDidChangeNotification"]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) { poll(); }];
        }

        // Safety net: notifications are occasionally dropped.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{ poll(); });
        dispatch_resume(timer);

        // Commands from the app; EOF means the app is gone, so exit with it.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char buffer[64];
            while (fgets(buffer, sizeof(buffer), stdin)) {
                NSString *command = [[NSString stringWithUTF8String:buffer]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(command); });
            }
            exit(0);
        });

        CFRunLoopRun();
        (void)timer;
    }
}
