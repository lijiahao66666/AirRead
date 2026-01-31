//
//  MnnLlmBridge.mm
//  AirRead
//
//  MNN LLM iOS Bridge Implementation
//

#import "MnnLlmBridge.h"
#import <Foundation/Foundation.h>

// 模拟器不支持 MNN
#if TARGET_OS_SIMULATOR
#define MNN_NOT_AVAILABLE 1
#else
#define MNN_NOT_AVAILABLE 0
#endif

#if !MNN_NOT_AVAILABLE
// 导入 MNN 头文件 (CocoaPods)
#import <MNN/MNN.h>
#endif

#include <mutex>
#include <sstream>
#include <string>

// 全局 LLM 实例和锁
static std::mutex g_llmMutex;
static void* g_llmInstance = nullptr;
static BOOL g_isCancelled = NO;

@implementation MnnLlmBridge

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
        
        std::lock_guard<std::mutex> lock(g_llmMutex);
        
        // 清理旧实例
        if (g_llmInstance) {
            g_llmInstance = nullptr;
        }
        
        // 模拟成功
        g_llmInstance = (void*)0x1;
        
        return YES;
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
        std::lock_guard<std::mutex> lock(g_llmMutex);
        
        if (!g_llmInstance) {
            return nil;
        }
        
        // 重置取消标志
        g_isCancelled = NO;
        
        // 模拟生成
        return @"这是一个模拟回复。实际集成 MNN 后将使用真实模型生成。";
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
            std::lock_guard<std::mutex> lock(g_llmMutex);
            
            if (!g_llmInstance) {
                if (onDone) {
                    onDone([NSError errorWithDomain:@"MnnLlmBridge"
                                               code:1005
                                           userInfo:@{NSLocalizedDescriptionKey: @"LLM not initialized"}]);
                }
                return;
            }
            
            // 重置取消标志
            g_isCancelled = NO;
            
            // 模拟流式生成
            NSArray *mockChunks = @[@"这是", @"一个", @"模拟", @"的", @"流式", @"回复", @"。", @"实际", @"集成", @" MNN ", @"后", @"将", @"使用", @"真实", @"模型", @"生成", @"。"];
            for (NSString *chunk in mockChunks) {
                if (g_isCancelled) break;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!g_isCancelled && onChunk) {
                        onChunk(chunk);
                    }
                });
                
                [NSThread sleepForTimeInterval:0.1];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!g_isCancelled && onDone) {
                    onDone(nil);
                }
            });
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
    g_isCancelled = YES;
}

- (nullable NSString *)dumpConfig {
#if MNN_NOT_AVAILABLE
    return nil;
#else
    @try {
        std::lock_guard<std::mutex> lock(g_llmMutex);
        
        if (!g_llmInstance) {
            return nil;
        }
        
        return @"{\"model\":\"MiniCPM-0.5B\",\"backend\":\"CPU\",\"threads\":4}";
    } @catch (NSException *exception) {
        NSLog(@"[MnnLlmBridge] Exception: %@", exception.reason);
        return nil;
    }
#endif
}

@end
