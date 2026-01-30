#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MnnLlmBridge : NSObject

+ (BOOL)isAvailable;

+ (BOOL)loadModel:(NSString *)path
            error:(NSError **)error
    NS_SWIFT_NOTHROW;

+ (nullable NSString *)getConfig:(NSError **)error
    NS_SWIFT_NOTHROW;

+ (void)cancelStream;

+ (nullable NSString *)generate:(NSString *)prompt
                   maxNewTokens:(int)maxNewTokens
                 maxInputTokens:(int)maxInputTokens
                    temperature:(double)temperature
                           topP:(double)topP
                           topK:(int)topK
                           minP:(double)minP
                presencePenalty:(double)presencePenalty
              repetitionPenalty:(double)repetitionPenalty
                 enableThinking:(int)enableThinking
                          error:(NSError **)error
    NS_SWIFT_NOTHROW;

+ (void)generateStream:(NSString *)prompt
          maxNewTokens:(int)maxNewTokens
        maxInputTokens:(int)maxInputTokens
           temperature:(double)temperature
                  topP:(double)topP
                  topK:(int)topK
                  minP:(double)minP
       presencePenalty:(double)presencePenalty
     repetitionPenalty:(double)repetitionPenalty
        enableThinking:(int)enableThinking
               onChunk:(void (^)(NSString * _Nullable chunk))onChunk
                onDone:(void (^)(NSError * _Nullable error))onDone;

@end

NS_ASSUME_NONNULL_END
