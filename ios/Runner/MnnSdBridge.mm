#import "MnnSdBridge.h"

typedef enum {
  MNN_FORWARD_CPU = 0,
} MNNForwardType;

#include <functional>
#include <memory>
#include <string>

namespace MNN {
namespace DIFFUSION {
enum DiffusionModelType {
  STABLE_DIFFUSION_1_5 = 0,
};

class Diffusion {
 public:
  static Diffusion* createDiffusion(std::string modelPath,
                                    DiffusionModelType modelType,
                                    MNNForwardType backendType,
                                    int memoryMode);
  bool load();
  bool run(const std::string prompt,
           const std::string imagePath,
           int iterNum,
           int randomSeed,
           std::function<void(int)> progressCallback);
};
}  // namespace DIFFUSION
}  // namespace MNN

static std::unique_ptr<MNN::DIFFUSION::Diffusion> g_diffusion;

@implementation MnnSdBridge

+ (BOOL)isAvailable {
  return YES;
}

- (void)initialize:(NSString *)modelDir completion:(void (^)(BOOL success))completion {
  std::string dir = modelDir != nil ? std::string([modelDir UTF8String]) : std::string();
  if (dir.empty()) {
    if (completion) completion(NO);
    return;
  }
  g_diffusion.reset(MNN::DIFFUSION::Diffusion::createDiffusion(
      dir, MNN::DIFFUSION::STABLE_DIFFUSION_1_5, MNN_FORWARD_CPU, 2));
  if (!g_diffusion) {
    if (completion) completion(NO);
    return;
  }
  const bool ok = g_diffusion->load();
  if (completion) completion(ok);
}

- (nullable NSString *)txt2img:(NSString *)prompt steps:(NSInteger)steps seed:(NSInteger)seed {
  if (!g_diffusion) return nil;
  std::string p = prompt != nil ? std::string([prompt UTF8String]) : std::string();
  if (p.empty()) return nil;
  NSInteger iter = steps;
  if (iter <= 0) iter = 10;
  const NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
  NSString *filename = [NSString stringWithFormat:@"airread_sd_%0.f.png", ts * 1000.0];
  NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
  std::string out = std::string([outPath UTF8String]);
  const bool ok = g_diffusion->run(p, out, (int)iter, (int)seed, [](int) {});
  if (!ok) return nil;
  if (![[NSFileManager defaultManager] fileExistsAtPath:outPath]) return nil;
  return outPath;
}

@end
