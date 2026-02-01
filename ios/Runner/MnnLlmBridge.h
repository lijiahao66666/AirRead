//
//  MnnLlmBridge.h
//  AirRead
//
//  MNN LLM iOS Bridge Header
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MnnLlmBridge : NSObject

+ (BOOL)isAvailable;

- (void)initialize:(NSString *)modelPath completion:(void (^)(BOOL success))completion;

- (nullable NSString *)chatOnce:(NSString *)userText
                   maxNewTokens:(NSInteger)maxNewTokens
                  maxInputTokens:(NSInteger)maxInputTokens
                    temperature:(double)temperature
                           topP:(double)topP
                          topK:(NSInteger)topK
                          minP:(double)minP
                 presencePenalty:(double)presencePenalty
               repetitionPenalty:(double)repetitionPenalty
                  enableThinking:(BOOL)enableThinking;

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
            onDone:(void (^)(NSError * _Nullable error))onDone;

- (void)cancelCurrentStream;

- (nullable NSString *)dumpConfig;

@end

NS_ASSUME_NONNULL_END
