#import "MnnLlmBridge.h"

#import <MNN/llm/llm.hpp>

#include <streambuf>
#include <sstream>
#include <vector>
#include <atomic>

static std::unique_ptr<MNN::Transformer::Llm> g_llm;
static NSString* g_modelPath = nil;
static std::atomic<bool> g_cancelStream(false);

struct StreamCancelledException {};

static std::vector<int> trimPromptToTokens(MNN::Transformer::Llm* llm, const std::string& prompt, int max_input_tokens) {
  if (llm == nullptr) return {};
  const auto ids = llm->tokenizer_encode(prompt);
  if (max_input_tokens <= 0) return ids;
  if (static_cast<int>(ids.size()) <= max_input_tokens) return ids;

  int head = max_input_tokens / 4;
  if (head > 128) head = 128;
  if (head < 0) head = 0;
  if (head > max_input_tokens) head = max_input_tokens;
  int tail = max_input_tokens - head;

  std::vector<int> out;
  out.reserve(static_cast<size_t>(max_input_tokens));

  if (head > 0) {
    out.insert(out.end(), ids.begin(), ids.begin() + head);
  }

  if (tail > 0) {
    const auto sep = llm->tokenizer_encode("\n");
    if (!sep.empty()) {
      out.insert(out.end(), sep.begin(), sep.end());
    }
    const size_t total = ids.size();
    const size_t tailStart = total > static_cast<size_t>(tail) ? (total - static_cast<size_t>(tail)) : 0;
    out.insert(out.end(), ids.begin() + tailStart, ids.end());
  }

  if (static_cast<int>(out.size()) > max_input_tokens) {
    out.erase(out.begin() + max_input_tokens, out.end());
  }
  return out;
}

static void applyRuntimeConfig(
    MNN::Transformer::Llm* llm,
    double temperature,
    double top_p,
    int top_k,
    double min_p,
    double presence_penalty,
    double repetition_penalty,
    int enable_thinking
) {
  if (llm == nullptr) return;

  std::ostringstream os;
  bool hasAny = false;
  os << "{";

  auto addCommaIfNeeded = [&]() {
    if (hasAny) os << ",";
    hasAny = true;
  };

  if (temperature >= 0.0) {
    addCommaIfNeeded();
    os << "\"temperature\":" << temperature;
  }
  if (top_p >= 0.0) {
    addCommaIfNeeded();
    os << "\"top_p\":" << top_p;
  }
  if (top_k >= 0) {
    addCommaIfNeeded();
    os << "\"top_k\":" << top_k;
  }
  if (min_p >= 0.0) {
    addCommaIfNeeded();
    os << "\"min_p\":" << min_p;
  }
  if (presence_penalty >= 0.0) {
    addCommaIfNeeded();
    os << "\"presence_penalty\":" << presence_penalty;
  }
  if (repetition_penalty >= 0.0) {
    addCommaIfNeeded();
    os << "\"repetition_penalty\":" << repetition_penalty;
  }
  if (enable_thinking == 0 || enable_thinking == 1) {
    addCommaIfNeeded();
    os << "\"enable_thinking\":" << (enable_thinking == 1 ? "true" : "false");
  }

  os << "}";
  if (!hasAny) return;
  llm->set_config(os.str());
}

static std::string toChatPrompt(MNN::Transformer::Llm* llm, const std::string& user_content) {
  if (llm == nullptr) return user_content;
  std::string out;
  try {
    out = llm->apply_chat_template(user_content);
  } catch (...) {
    out.clear();
  }
  if (out.empty()) return user_content;
  return out;
}

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
    try {
      flushPending(true);
    } catch (...) {
    }
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
    if (g_cancelStream.load()) {
      pending_.clear();
      throw StreamCancelledException();
    }
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

+ (NSString*)dumpConfigWithError:(NSError**)error {
  if (!g_llm) {
    if (error) {
      *error = [NSError errorWithDomain:@"MnnLlmBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"模型未初始化"}];
    }
    return @"";
  }

  const auto cfg = g_llm->dump_config();
  NSString* resp = [[NSString alloc] initWithBytes:cfg.data() length:cfg.size() encoding:NSUTF8StringEncoding];
  if (resp == nil) {
    resp = [[NSString alloc] initWithCString:cfg.c_str() encoding:NSUTF8StringEncoding];
  }
  return resp ?: @"";
}

+ (void)cancelCurrentStream {
  g_cancelStream.store(true);
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
  applyRuntimeConfig(g_llm.get(), temperature, topP, topK, minP, presencePenalty, repetitionPenalty, enableThinking);
  std::stringstream ss;
  const std::string input([prompt UTF8String]);
  const std::string chatPrompt = toChatPrompt(g_llm.get(), input);
  const int maxTokens = maxNewTokens > 0 ? maxNewTokens : 256;
  const char* endWith = "<|im_end|>";
  if (maxInputTokens > 0) {
    const auto ids = trimPromptToTokens(g_llm.get(), chatPrompt, maxInputTokens);
    g_llm->response(ids, &ss, endWith, maxTokens);
  } else {
    g_llm->response(chatPrompt, &ss, endWith, maxTokens);
  }
  const auto out = ss.str();

  NSString* resp = [[NSString alloc] initWithBytes:out.data() length:out.size() encoding:NSUTF8StringEncoding];
  if (resp == nil) {
    resp = [[NSString alloc] initWithCString:out.c_str() encoding:NSUTF8StringEncoding];
  }
  return resp ?: @"";
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
  applyRuntimeConfig(g_llm.get(), temperature, topP, topK, minP, presencePenalty, repetitionPenalty, enableThinking);
  g_cancelStream.store(false);
  const std::string input([prompt UTF8String]);
  const std::string chatPrompt = toChatPrompt(g_llm.get(), input);
  BlockStreamBuf buf(onChunk);
  std::ostream os(&buf);
  const int maxTokens = maxNewTokens > 0 ? maxNewTokens : 256;
  const char* endWith = "<|im_end|>";
  if (maxInputTokens > 0) {
    const auto ids = trimPromptToTokens(g_llm.get(), chatPrompt, maxInputTokens);
    try {
      g_llm->response(ids, &os, endWith, maxTokens);
    } catch (const StreamCancelledException&) {
    }
  } else {
    try {
      g_llm->response(chatPrompt, &os, endWith, maxTokens);
    } catch (const StreamCancelledException&) {
    }
  }
  os.flush();
  if (onDone) onDone(nil);
}

@end
