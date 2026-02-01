//
//  MnnLlmBridge.mm
//  AirRead
//
//  MNN LLM iOS Bridge Implementation
//

#import "MnnLlmBridge.h"
#import "LLMInferenceEngineWrapper.h"
#import <Foundation/Foundation.h>

// 模拟器不支持 MNN
#if TARGET_OS_SIMULATOR
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

- (BOOL)initialize:(NSString *)modelPath {
#if MNN_NOT_AVAILABLE
    return NO;
#else
    @try {
        // 检查配置文件是否存在
        NSString *configPath = [modelPath stringByAppendingPathComponent:@"config.json"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
            NSLog(@"[MnnLlmBridge] Config file not found at %@", configPath);
            return NO;
        }
        
        _modelPath = modelPath;
        
        // 使用 LLMInferenceEngineWrapper 初始化
        __block BOOL initSuccess = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        _engine = [[LLMInferenceEngineWrapper alloc] initWithModelPath:modelPath completion:^(BOOL success) {
            initSuccess = success;
            dispatch_semaphore_signal(semaphore);
        }];
        
        // 等待初始化完成（最多30秒）
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        
        return initSuccess;
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Exception: %@", exception.reason);
        return NO;
    }
#endif
}

- (nullable NSString *)chatOnce:(NSString *)userText
                   maxNewTokens:(NSInteger)maxNewTokens
                  maxInputTokens:(NSInteger)maxInputTokens
                    temperature:(double)temperature
                           topP:(double)topP
                          topK:(NSInteger)topK
                          minP:(double)minP
                 presencePenalty:(double)presencePenalty
               repetitionPenalty:(double)repetitionPenalty
                  enableThinking:(BOOL)enableThinking {
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
                 maxNewTokens:maxNewTokens
               maxInputTokens:maxInputTokens
                  temperature:temperature
                         topP:topP
                         topK:topK
                         minP:minP
              presencePenalty:presencePenalty
            repetitionPenalty:repetitionPenalty
               enableThinking:enableThinking
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
      maxNewTokens:(NSInteger)maxNewTokens
     maxInputTokens:(NSInteger)maxInputTokens
       temperature:(double)temperature
              topP:(double)topP
             topK:(NSInteger)topK
             minP:(double)minP
    presencePenalty:(double)presencePenalty
  repetitionPenalty:(double)repetitionPenalty
     enableThinking:(BOOL)enableThinking
           onChunk:(void (^)(NSString *chunk))onChunk
            onDone:(void (^)(NSError * _Nullable error))onDone {
#if MNN_NOT_AVAILABLE
    if (onDone) {
        onDone([NSError errorWithDomain:@"MnnLlmBridge"
                                   code:1001
                               userInfo:@{NSLocalizedDescriptionKey: @"MNN not available on simulator"}]);
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
                           maxNewTokens:maxNewTokens
                         maxInputTokens:maxInputTokens
                            temperature:temperature
                                   topP:topP
                                   topK:topK
                                   minP:minP
                        presencePenalty:presencePenalty
                      repetitionPenalty:repetitionPenalty
                         enableThinking:enableThinking
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

@end
