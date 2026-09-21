#import "./include/just_audio/JustAudioPlugin.h"
#import "./include/just_audio/AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#include <TargetConditionals.h>

@implementation JustAudioPlugin {
    NSObject<FlutterPluginRegistrar>* _registrar;
    NSMutableDictionary<NSString *, AudioPlayer *> *_players;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
        methodChannelWithName:@"com.ryanheise.just_audio.methods"
              binaryMessenger:[registrar messenger]];
    JustAudioPlugin* instance = [[JustAudioPlugin alloc] initWithRegistrar:registrar];
    [registrar addMethodCallDelegate:instance channel:channel];

    // 反射调用宿主 App 的 Runner.AudioEqualizer.bootstrapWithBinaryMessenger:
    // （插件与 App 分属不同 framework 模块，无法直接 import；插件注册早于
    // 任何播放，保证均衡器在首个 AVPlayerItem 创建前完成观察者安装）
    Class eqClass = NSClassFromString(@"Runner.AudioEqualizer");
    SEL sel = NSSelectorFromString(@"bootstrapWithBinaryMessenger:");
    if (eqClass && [eqClass respondsToSelector:sel]) {
        [eqClass performSelector:sel withObject:[registrar messenger]];
    }
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _players = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    //NSLog(@"plugin method: %@", call.method);
    if ([@"init" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = (NSString *)request[@"id"];
        NSDictionary *loadConfiguration = (NSDictionary *)request[@"audioLoadConfiguration"];
        BOOL useLazyPreparation = [((NSNumber *)request[@"useLazyPreparation"]) boolValue];
        if ([_players objectForKey:playerId] != nil) {
            FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Platform player already exists" details:nil];
            result(flutterError);
        } else {
            AudioPlayer* player = [[AudioPlayer alloc] initWithRegistrar:_registrar playerId:playerId loadConfiguration:loadConfiguration useLazyPreparation:useLazyPreparation];
            [_players setValue:player forKey:playerId];
            result(nil);
        }
    } else if ([@"disposePlayer" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = request[@"id"];
        [_players[playerId] dispose:NO];
        [_players setValue:nil forKey:playerId];
        result(@{});
    } else if ([@"disposeAllPlayers" isEqualToString:call.method]) {
        for (NSString *playerId in _players) {
            [_players[playerId] dispose:NO];
        }
        [_players removeAllObjects];
        result(@{});
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)dealloc {
    for (NSString *playerId in _players) {
        [_players[playerId] dispose:YES];
    }
    [_players removeAllObjects];
}

@end
