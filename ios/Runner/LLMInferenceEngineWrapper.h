//
//  LLMInferenceEngineWrapper.h
//  AirRead
//
//  MNN LLM Inference Engine Wrapper for iOS
//

#ifndef LLMInferenceEngineWrapper_h
#define LLMInferenceEngineWrapper_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^ModelLoadingCompletionHandler)(BOOL success);
typedef void (^StreamOutputHandler)(NSString * _Nonnull output);

@interface LLMInferenceEngineWrapper : NSObject

- (instancetype)initWithModelPath:(NSString *)modelPath
                       completion:(ModelLoadingCompletionHandler)completionHandler;

- (void)processInput:(NSString *)input
        maxNewTokens:(NSInteger)maxNewTokens
      maxInputTokens:(NSInteger)maxInputTokens
         temperature:(double)temperature
                topP:(double)topP
                topK:(NSInteger)topK
                minP:(double)minP
     presencePenalty:(double)presencePenalty
   repetitionPenalty:(double)repetitionPenalty
      enableThinking:(BOOL)enableThinking
   withStreamHandler:(StreamOutputHandler)handler;

- (void)cancelInference;

- (void)clearHistory;

- (BOOL)isModelReady;

- (BOOL)isProcessing;

@end

NS_ASSUME_NONNULL_END

#endif /* LLMInferenceEngineWrapper_h */
