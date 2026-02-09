#import "MnnSdBridge.h"

#import <MNN/MNNForwardType.h>

#include <functional>
#include <memory>
#include <string>

namespace MNN {
namespace DIFFUSION {
enum DiffusionModelType {
  StableDiffusion = 0,
};

class Diffusion {
 public:
  static Diffusion* createDiffusion(std::string modelDir,
                                    DiffusionModelType type,
                                    MNNForwardType forwardType,
                                    int threadCount);
  std::string run(std::string prompt,
                  std::string negativePrompt,
                  int steps,
                  int seed,
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
      dir, MNN::DIFFUSION::StableDiffusion, MNN_FORWARD_CPU, 4));
  if (completion) completion(g_diffusion != nullptr);
}

- (nullable NSString *)txt2img:(NSString *)prompt steps:(NSInteger)steps seed:(NSInteger)seed {
  if (!g_diffusion) return nil;
  std::string p = prompt != nil ? std::string([prompt UTF8String]) : std::string();
  if (p.empty()) return nil;
  const std::string negative =
      "text, watermark, logo, blurry, deformed, extra limbs, low quality";
  std::string outPath =
      g_diffusion->run(p, negative, (int)steps, (int)seed, [](int) {});
  if (outPath.empty()) return nil;
  return [NSString stringWithUTF8String:outPath.c_str()];
}

@end
