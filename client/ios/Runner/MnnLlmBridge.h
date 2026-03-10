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

- (nullable NSString *)chatOnce:(NSString *)userText;

- (void)chatStream:(NSString *)userText
           onChunk:(void (^)(NSString *chunk))onChunk
            onDone:(void (^)(NSError * _Nullable error))onDone;

- (void)cancelCurrentStream;

- (nullable NSString *)dumpConfig;

- (void)dispose;

@end

NS_ASSUME_NONNULL_END
