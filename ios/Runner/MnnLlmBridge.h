#import <Foundation/Foundation.h>

@interface MnnLlmBridge : NSObject
+ (BOOL)isAvailable;
+ (void)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error;
+ (NSString*)chatOnce:(NSString*)prompt error:(NSError**)error;
+ (void)chatStream:(NSString*)prompt
           onChunk:(void (^)(NSString* chunk))onChunk
            onDone:(void (^)(NSError* _Nullable error))onDone;
@end
