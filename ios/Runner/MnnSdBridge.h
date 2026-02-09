#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MnnSdBridge : NSObject

+ (BOOL)isAvailable;

- (void)initialize:(NSString *)modelDir completion:(void (^)(BOOL success))completion;

- (nullable NSString *)txt2img:(NSString *)prompt
                         steps:(NSInteger)steps
                          seed:(NSInteger)seed;

@end

NS_ASSUME_NONNULL_END

