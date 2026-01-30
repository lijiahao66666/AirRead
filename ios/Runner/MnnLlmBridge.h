#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MnnLlmBridge : NSObject
+ (BOOL)isAvailable;
+ (BOOL)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error;
+ (nullable NSString*)dumpConfigWithError:(NSError**)error;
+ (void)cancelCurrentStream;
+ (nullable NSString*)chatOnce:(NSString*)prompt
                  maxNewTokens:(int)maxNewTokens
                maxInputTokens:(int)maxInputTokens
                   temperature:(double)temperature
                          topP:(double)topP
                          topK:(int)topK
                          minP:(double)minP
                presencePenalty:(double)presencePenalty
              repetitionPenalty:(double)repetitionPenalty
                 enableThinking:(int)enableThinking
                          error:(NSError**)error;
+ (void)chatStream:(NSString*)prompt
      maxNewTokens:(int)maxNewTokens
    maxInputTokens:(int)maxInputTokens
       temperature:(double)temperature
              topP:(double)topP
              topK:(int)topK
              minP:(double)minP
    presencePenalty:(double)presencePenalty
  repetitionPenalty:(double)repetitionPenalty
     enableThinking:(int)enableThinking
          onChunk:(void (^)(NSString* _Nullable chunk))onChunk
           onDone:(void (^)(NSError* _Nullable error))onDone;

@end

NS_ASSUME_NONNULL_END
