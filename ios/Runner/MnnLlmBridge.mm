#import "MnnLlmBridge.h"

#import <MNN/llm/llm.hpp>

#include <streambuf>

static std::unique_ptr<MNN::Transformer::Llm> g_llm;
static NSString* g_modelPath = nil;

static size_t validUtf8Prefix(const std::string& s) {
  size_t i = 0;
  const size_t n = s.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t len = 0;
    if (c <= 0x7F) {
      len = 1;
    } else if ((c & 0xE0) == 0xC0) {
      len = 2;
    } else if ((c & 0xF0) == 0xE0) {
      len = 3;
    } else if ((c & 0xF8) == 0xF0) {
      len = 4;
    } else {
      break;
    }
    if (i + len > n) break;
    for (size_t j = 1; j < len; j++) {
      unsigned char cc = static_cast<unsigned char>(s[i + j]);
      if ((cc & 0xC0) != 0x80) return i;
    }
    i += len;
  }
  return i;
}

class BlockStreamBuf : public std::streambuf {
public:
  BlockStreamBuf(void (^onChunk)(NSString* chunk)) : onChunk_([onChunk copy]) {}

  ~BlockStreamBuf() override {
    flushPending(true);
  }

protected:
  int overflow(int ch) override {
    if (ch == EOF) {
      flushPending(true);
      return 0;
    }
    pending_.push_back(static_cast<char>(ch));
    flushPending(false);
    return ch;
  }

  std::streamsize xsputn(const char* s, std::streamsize n) override {
    if (n <= 0) return 0;
    pending_.append(s, static_cast<size_t>(n));
    flushPending(false);
    return n;
  }

private:
  void flushPending(bool force) {
    if (pending_.empty()) return;
    if (!force && pending_.size() < 48) return;
    if (!onChunk_) {
      pending_.clear();
      return;
    }
    const auto prefixLen = validUtf8Prefix(pending_);
    if (prefixLen == 0) {
      if (force) pending_.clear();
      return;
    }
    const std::string out = pending_.substr(0, prefixLen);
    pending_.erase(0, prefixLen);

    NSString* chunk =
        [[NSString alloc] initWithBytes:out.data() length:out.size() encoding:NSUTF8StringEncoding];
    if (chunk == nil) {
      chunk = [[NSString alloc] initWithCString:out.c_str() encoding:NSUTF8StringEncoding];
    }
    if (chunk != nil && chunk.length > 0) {
      onChunk_(chunk);
    }
  }

private:
  __strong void (^onChunk_)(NSString* chunk);
  std::string pending_;
};

@implementation MnnLlmBridge

+ (BOOL)isAvailable {
  return YES;
}

+ (void)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error {
  if (modelPath == nil || modelPath.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"MnnLlmBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"modelPath 为空"}];
    }
    return;
  }

  if (g_modelPath != nil && [g_modelPath isEqualToString:modelPath] && g_llm) {
    return;
  }

  g_modelPath = [modelPath copy];
  std::string path([g_modelPath UTF8String]);
  g_llm.reset(MNN::Transformer::Llm::createLLM(path));
  if (!g_llm) {
    if (error) {
      *error = [NSError errorWithDomain:@"MnnLlmBridge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"创建模型实例失败"}];
    }
    return;
  }

  const auto ok = g_llm->load();
  if (!ok) {
    if (error) {
      *error = [NSError errorWithDomain:@"MnnLlmBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"模型加载失败"}];
    }
    return;
  }
}

+ (NSString*)chatOnce:(NSString*)prompt error:(NSError**)error {
  if (!g_llm) {
    if (error) {
      *error = [NSError errorWithDomain:@"MnnLlmBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"模型未初始化"}];
    }
    return @"";
  }
  if (prompt == nil) {
    return @"";
  }

  g_llm->reset();
  std::stringstream ss;
  std::string input([prompt UTF8String]);
  g_llm->response(input, &ss, nullptr, 256);
  const auto out = ss.str();

  NSString* resp = [[NSString alloc] initWithBytes:out.data() length:out.size() encoding:NSUTF8StringEncoding];
  if (resp == nil) {
    resp = [[NSString alloc] initWithCString:out.c_str() encoding:NSUTF8StringEncoding];
  }
  return resp ?: @"";
}

+ (void)chatStream:(NSString*)prompt
           onChunk:(void (^)(NSString* chunk))onChunk
            onDone:(void (^)(NSError* _Nullable error))onDone {
  if (!g_llm) {
    if (onDone) {
      onDone([NSError errorWithDomain:@"MnnLlmBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"模型未初始化"}]);
    }
    return;
  }
  if (prompt == nil) {
    if (onDone) onDone(nil);
    return;
  }

  g_llm->reset();
  std::string input([prompt UTF8String]);
  BlockStreamBuf buf(onChunk);
  std::ostream os(&buf);
  g_llm->response(input, &os, nullptr, 256);
  os.flush();
  if (onDone) onDone(nil);
}

@end
