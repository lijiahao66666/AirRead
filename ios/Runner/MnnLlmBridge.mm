#import "MnnLlmBridge.h"

@implementation MnnLlmBridge

+ (BOOL)isAvailable {
    return NO;
}

+ (void)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error {
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge" 
                                     code:1001 
                                 userInfo:@{NSLocalizedDescriptionKey: @"MNN framework not available in this build"}];
    }
}

+ (NSString*)dumpConfigWithError:(NSError**)error {
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge" 
                                     code:1002 
                                 userInfo:@{NSLocalizedDescriptionKey: @"MNN framework not available"}];
    }
    return nil;
}

+ (void)cancelCurrentStream {
    // No-op
}

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
                error:(NSError**)error {
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge" 
                                     code:1003 
                                 userInfo:@{NSLocalizedDescriptionKey: @"Local LLM not available. Please use cloud API instead."}];
    }
    return nil;
}

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
            onDone:(void (^)(NSError* _Nullable error))onDone {
    if (onDone) {
        NSError *error = [NSError errorWithDomain:@"MnnLlmBridge" 
                                             code:1004 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Local LLM not available. Please use cloud API instead."}];
        onDone(error);
    }
}

@end
