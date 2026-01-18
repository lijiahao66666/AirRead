#import <Foundation/Foundation.h>

@interface MnnLlmBridge : NSObject
+ (BOOL)isAvailable;
+ (void)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error;
+ (NSString*)dumpConfigWithError:(NSError**)error;
+ (void)cancelCurrentStream;
+ (NSString*)chatOnce:(NSString*)prompt
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
           onChunk:(void (^)(NSString* chunk))onChunk
            onDone:(void (^)(NSError* _Nullable error))onDone;
@end
