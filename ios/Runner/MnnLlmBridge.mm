//
//  MnnLlmBridge.mm
//  AirRead
//
//  MNN LLM iOS Bridge Implementation
//

#import "MnnLlmBridge.h"
#import "LLMInferenceEngineWrapper.h"
#import <Foundation/Foundation.h>

// 模拟器支持情况：
// - Apple Silicon 模拟器（arm64）可用
// - Intel 模拟器（x86_64）不可用
#if TARGET_OS_SIMULATOR && !defined(__arm64__)
#define MNN_NOT_AVAILABLE 1
#else
#define MNN_NOT_AVAILABLE 0
#endif

@implementation MnnLlmBridge {
    LLMInferenceEngineWrapper *_engine;
    NSString *_modelPath;
}

+ (BOOL)isAvailable {
#if MNN_NOT_AVAILABLE
    return NO;
#else
    return YES;
#endif
}

- (void)initialize:(NSString *)modelPath completion:(void (^)(BOOL success))completion {
#if MNN_NOT_AVAILABLE
    if (completion) completion(NO);
#else
    @try {
        // 检查配置文件是否存在
        NSString *configPath = [modelPath stringByAppendingPathComponent:@"config.json"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
            NSLog(@"[MnnLlmBridge] Config file not found at %@", configPath);
            if (completion) completion(NO);
            return;
        }
        
        _modelPath = modelPath;
        
        NSLog(@"[MnnLlmBridge] Starting initialization with path: %@", modelPath);
        
        // 异步初始化，不再阻塞等待
        _engine = [[LLMInferenceEngineWrapper alloc] initWithModelPath:modelPath completion:^(BOOL success) {
            if (success) {
                NSLog(@"[MnnLlmBridge] LLMInferenceEngineWrapper initialized successfully");
            } else {
                NSLog(@"[MnnLlmBridge] LLMInferenceEngineWrapper initialization failed");
            }
            if (completion) {
                completion(success);
            }
        }];
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Exception: %@", exception.reason);
        if (completion) completion(NO);
    }
#endif
}

- (nullable NSString *)chatOnce:(NSString *)userText {
#if MNN_NOT_AVAILABLE
    return nil;
#else
    @try {
        if (!_engine || ![_engine isModelReady]) {
            return nil;
        }
        
        __block NSString *fullResponse = @"";
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        [_engine processInput:userText
            withStreamHandler:^(NSString * _Nonnull output) {
            if ([output isEqualToString:@"<eop>"]) {
                dispatch_semaphore_signal(semaphore);
            } else {
                fullResponse = [fullResponse stringByAppendingString:output];
            }
        }];
        
        // 等待生成完成（最多60秒）
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
        
        return fullResponse;
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Exception: %@", exception.reason);
        return nil;
    }
#endif
}

- (void)chatStream:(NSString *)userText
           onChunk:(void (^)(NSString *chunk))onChunk
            onDone:(void (^)(NSError * _Nullable error))onDone {
#if MNN_NOT_AVAILABLE
    if (onDone) {
        onDone([NSError errorWithDomain:@"MnnLlmBridge"
                                   code:1001
                               userInfo:@{NSLocalizedDescriptionKey: @"MNN not available on x86_64 simulator"}]);
    }
    return;
#else
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (!self->_engine || ![self->_engine isModelReady]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (onDone) {
                        onDone([NSError errorWithDomain:@"MnnLlmBridge"
                                                   code:1005
                                               userInfo:@{NSLocalizedDescriptionKey: @"LLM not initialized"}]);
                    }
                });
                return;
            }
            
            [self->_engine processInput:userText
                      withStreamHandler:^(NSString * _Nonnull output) {
                if ([output isEqualToString:@"<eop>"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (onDone) {
                            onDone(nil);
                        }
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (onChunk) {
                            onChunk(output);
                        }
                    });
                }
            }];
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (onDone) {
                    onDone([NSError errorWithDomain:@"MnnLlmBridge"
                                               code:1007
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}]);
                }
            });
        }
    });
#endif
}

- (void)cancelCurrentStream {
    // LLMInferenceEngineWrapper 支持取消
    [_engine cancelInference];
}

- (nullable NSString *)dumpConfig {
#if MNN_NOT_AVAILABLE
    return nil;
#else
    @try {
        if (!_engine || ![_engine isModelReady]) {
            return nil;
        }
        
        return [@{@"model": _modelPath ?: @"unknown", @"backend": @"MNN", @"ready": @YES} description];
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Exception: %@", exception.reason);
        return nil;
    }
#endif
}

- (void)dispose {
#if MNN_NOT_AVAILABLE
    return;
#else
    @try {
        if (_engine) {
            NSLog(@"[MnnLlmBridge] Disposing model: %@", _modelPath);
            [_engine cancelInference];
            [_engine dispose];
        }
        _engine = nil;
        _modelPath = nil;
        NSLog(@"[MnnLlmBridge] Dispose completed");
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Dispose exception: %@", exception.reason);
    }
#endif
}

@end
