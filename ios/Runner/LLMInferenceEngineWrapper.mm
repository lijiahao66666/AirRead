//
//  LLMInferenceEngineWrapper.mm
//  AirRead
//
//  MNN LLM Inference Engine Wrapper for iOS
//

#include <functional>
#include <sstream>
#include <string>
#include <mutex>
#include <atomic>
#include <vector>
#include <utility>
#include <cctype>
#include <TargetConditionals.h>
#import "LLMInferenceEngineWrapper.h"

// MNN Headers
#import <MNN/llm/llm.hpp>
using namespace MNN::Transformer;

using ChatMessage = std::pair<std::string, std::string>;

#if __cplusplus
namespace {
static std::string arTrimAscii(const std::string& s) {
    if (s.empty()) return s;
    const char* ws = " \n\r\t";
    const auto start = s.find_first_not_of(ws);
    if (start == std::string::npos) return "";
    const auto end = s.find_last_not_of(ws);
    return s.substr(start, end - start + 1);
}

static bool arLooksMeaningfulUtf8(const std::string& s) {
    const std::string t = arTrimAscii(s);
    if (t.empty()) return false;
    if (t.rfind("Error:", 0) == 0) return false;
    if (t.rfind("[错误]", 0) == 0) return false;
    if (t.rfind("错误:", 0) == 0) return false;
    if (t.rfind("错误：", 0) == 0) return false;
    for (size_t i = 0; i < t.size(); i++) {
        const unsigned char c = (unsigned char)t[i];
        if (std::isalnum(c)) return true;
        if (c >= 0xE4 && c <= 0xE9) return true;
    }
    return false;
}
} // namespace
#endif

#if DEBUG
#define ARLog(...) NSLog(__VA_ARGS__)
#else
#define ARLog(...)
#endif

// UTF-8 安全流缓冲区 - 累积字节直到形成完整UTF-8字符
class Utf8SafeStreamBuffer : public std::streambuf {
public:
    using CallBack = std::function<void(const char* str, size_t len)>;
    
    Utf8SafeStreamBuffer(CallBack callback) : callback_(callback) {
        // 设置内部缓冲区
        setp(buffer_, buffer_ + sizeof(buffer_) - 1);
    }
    
    ~Utf8SafeStreamBuffer() {
        sync();
        flushRemaining();
    }

protected:
    // 处理单个字符输出 (operator<< char 会调用此方法)
    virtual int_type overflow(int_type ch) override {
        if (ch == traits_type::eof()) {
            return traits_type::not_eof(ch);
        }
        
        // 将字符添加到字节缓冲区
        byteBuffer_.push_back(static_cast<char>(ch));
        
        // 尝试处理完整的UTF-8字符
        processUtf8Buffer();
        
        return ch;
    }
    
    // 处理批量输出 (write/<< string 会调用此方法)
    virtual std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (!callback_ || n <= 0) {
            return n;
        }
        
        // 将新数据添加到字节缓冲区
        byteBuffer_.append(s, n);
        
        // 尝试提取完整的UTF-8字符
        processUtf8Buffer();
        
        return n;
    }
    
    // 同步缓冲区
    virtual int sync() override {
        processUtf8Buffer();
        return 0;
    }

private:
    void processUtf8Buffer() {
        size_t i = 0;
        std::string outputStr;
        outputStr.reserve(byteBuffer_.size());
        
        while (i < byteBuffer_.size()) {
            unsigned char c = static_cast<unsigned char>(byteBuffer_[i]);
            size_t charLen = getUtf8CharLength(c);
            
            // 检查是否有足够的字节
            if (i + charLen <= byteBuffer_.size()) {
                // 验证UTF-8序列有效性
                if (isValidUtf8Sequence(byteBuffer_.c_str() + i, charLen)) {
                    outputStr.append(byteBuffer_.c_str() + i, charLen);
                    i += charLen;
                } else {
                    // 无效序列，跳过这个字节
                    ARLog(@"[Utf8SafeStreamBuffer] Invalid UTF-8 sequence at %zu, byte: 0x%02X", i, c);
                    invalidBytes_++;
                    i++;
                }
            } else {
                // 不完整的字符，停止处理，保留到下一次
                break;
            }
        }
        
        // 发送完整的UTF-8字符串
        if (!outputStr.empty() && callback_) {
            // NSMutableString *hex = [NSMutableString stringWithCapacity:(NSUInteger)outputStr.size() * 3];
            // size_t n = outputStr.size() > 16 ? 16 : outputStr.size();
            // for (size_t j = 0; j < n; j++) {
            //     [hex appendFormat:@"%02X ", (unsigned char)outputStr[j]];
            // }
            // ARLog(@"[Utf8SafeStreamBuffer] Sending %zu bytes, first=%@", outputStr.size(), hex);
            callback_(outputStr.c_str(), outputStr.size());
        }
        
        // 移除已处理的数据
        if (i > 0) {
            byteBuffer_.erase(0, i);
        }
    }
    
    size_t getUtf8CharLength(unsigned char firstByte) {
        if ((firstByte & 0x80) == 0) {
            return 1;  // ASCII: 0xxxxxxx
        } else if ((firstByte & 0xE0) == 0xC0) {
            return 2;  // 2-byte UTF-8: 110xxxxx
        } else if ((firstByte & 0xF0) == 0xE0) {
            return 3;  // 3-byte UTF-8: 1110xxxx (中文)
        } else if ((firstByte & 0xF8) == 0xF0) {
            return 4;  // 4-byte UTF-8: 11110xxx
        }
        // 无效的起始字节 (10xxxxxx 是 continuation byte)
        NSLog(@"[Utf8SafeStreamBuffer] Invalid UTF-8 start byte: 0x%02X", firstByte);
        return 1;  // 按单字节处理，跳过
    }
    
    bool isValidUtf8Sequence(const char* bytes, size_t len) {
        if (len == 1) {
            return (static_cast<unsigned char>(bytes[0]) & 0x80) == 0;
        }
        
        // 验证 continuation bytes (10xxxxxx)
        for (size_t i = 1; i < len; i++) {
            unsigned char c = static_cast<unsigned char>(bytes[i]);
            if ((c & 0xC0) != 0x80) {
                return false;
            }
        }
        return true;
    }
    
    void flushRemaining() {
        if (callback_ && !byteBuffer_.empty()) {
            ARLog(@"[Utf8SafeStreamBuffer] Flushing remaining %zu bytes", byteBuffer_.size());
            // 尝试最后一次处理
            processUtf8Buffer();
            
            // 如果还有剩余数据，强制发送（可能有乱码但总比丢失好）
            if (!byteBuffer_.empty()) {
                callback_(byteBuffer_.c_str(), byteBuffer_.size());
                byteBuffer_.clear();
            }
        }
    }

private:
    CallBack callback_ = nullptr;
    std::string byteBuffer_;  // 字节级缓冲区
    char buffer_[1024];       // 内部缓冲区
    size_t invalidBytes_ = 0;
};

@interface LLMInferenceEngineWrapper () {
    std::shared_ptr<Llm> _llm;
    std::vector<ChatMessage> _history;
    std::mutex _historyMutex;
    std::mutex _mutex;
    std::atomic<bool> _isProcessing;
    std::atomic<bool> _shouldStop;
    NSString *_modelPath;
}
@end

@implementation LLMInferenceEngineWrapper

- (instancetype)initWithModelPath:(NSString *)modelPath
                       completion:(ModelLoadingCompletionHandler)completionHandler {
    self = [super init];
    if (self) {
        _modelPath = [modelPath copy];
        _isProcessing = false;
        _shouldStop = false;
        
        // Initialize with system prompt
        {
            std::lock_guard<std::mutex> lock(_historyMutex);
            _history.emplace_back(ChatMessage("system", "You are a helpful assistant."));
        }
        
        // Load model in background thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL success = [self loadModel];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completionHandler) {
                    completionHandler(success);
                }
            });
        });
    }
    return self;
}

- (BOOL)loadModel {
    std::lock_guard<std::mutex> lock(_mutex);
    
    if (_llm) {
        return YES;
    }
    
    try {
        @try {
            // Check if config.json exists
            NSString *configPath = [_modelPath stringByAppendingPathComponent:@"config.json"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
                NSLog(@"[LLMInferenceEngineWrapper] Config file not found at %@", configPath);
                return NO;
            }
            
            std::string config_path = [configPath UTF8String];
            
            // Create LLM instance
            _llm.reset(Llm::createLLM(config_path));
            if (!_llm) {
                NSLog(@"[LLMInferenceEngineWrapper] Failed to create LLM instance");
                return NO;
            }
            
            // Configure LLM - 最小化覆盖项，只设置运行必须参数
            NSString *tempDirectory = NSTemporaryDirectory();
            std::string configStr = "{"
                "\"tmp_path\":\"" + std::string([tempDirectory UTF8String]) + "\","
                "\"use_mmap\":false,"
                "\"backend_type\":\"cpu\""
                "}";
            bool loadConfigOk = _llm->set_config(configStr);
            ARLog(@"[LLMInferenceEngineWrapper] Using config with backend_type=cpu, tmp_path=%s, set_config=%s", configStr.c_str(), loadConfigOk ? "true" : "false");
            
            // Load model
            bool loaded = _llm->load();
            if (!loaded) {
                NSLog(@"[LLMInferenceEngineWrapper] _llm->load() returned false");
                _llm.reset();
                return NO;
            }
            
            std::string dumped = _llm->dump_config();
            ARLog(@"[LLMInferenceEngineWrapper] dump_config (first 400 chars):\n%.400s", dumped.c_str());

            ARLog(@"[LLMInferenceEngineWrapper] Model loaded successfully from %@", _modelPath);
            return YES;
        } @catch (NSException *exception) {
            NSLog(@"[LLMInferenceEngineWrapper] ObjC Exception during model loading: %@", exception.reason);
            _llm.reset();
            return NO;
        }
    } catch (const std::exception& e) {
        NSLog(@"[LLMInferenceEngineWrapper] C++ Exception during model loading: %s", e.what());
        _llm.reset();
        return NO;
    } catch (...) {
        NSLog(@"[LLMInferenceEngineWrapper] Unknown C++ Exception during model loading");
        _llm.reset();
        return NO;
    }
}

- (void)processInput:(NSString *)input
        maxNewTokens:(NSInteger)maxNewTokens
      maxInputTokens:(NSInteger)maxInputTokens
         temperature:(double)temperature
                topP:(double)topP
                topK:(NSInteger)topK
                minP:(double)minP
     presencePenalty:(double)presencePenalty
   repetitionPenalty:(double)repetitionPenalty
      enableThinking:(BOOL)enableThinking
   withStreamHandler:(StreamOutputHandler)handler {
    if (!_llm) {
        if (handler) {
            handler(@"Error: Model not loaded");
            handler(@"<eop>");
        }
        return;
    }
    
    if (_isProcessing.load()) {
        if (handler) {
            handler(@"Error: Another inference is in progress");
            handler(@"<eop>");
        }
        return;
    }
    
    _isProcessing = true;
    _shouldStop = false;
    
    // Store reference for block execution
    LLMInferenceEngineWrapper *blockSelf = self;
    NSInteger maxNewTokensForRun = maxNewTokens;
    NSInteger maxInputTokensForRun = maxInputTokens;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        try {
            @try {
                // 设置推理参数
                std::string configStr = "{";
                configStr += "\"max_new_tokens\": " + std::to_string(maxNewTokensForRun) + ",";
                configStr += "\"max_input_tokens\": " + std::to_string(maxInputTokensForRun) + ",";
                configStr += "\"temperature\": " + std::to_string(temperature) + ",";
                configStr += "\"top_p\": " + std::to_string(topP) + ",";
                configStr += "\"top_k\": " + std::to_string(topK) + ",";
                configStr += "\"min_p\": " + std::to_string(minP) + ",";
                configStr += "\"presence_penalty\": " + std::to_string(presencePenalty) + ",";
                configStr += "\"repetition_penalty\": " + std::to_string(repetitionPenalty);
                configStr += "}";
                
                bool inferConfigOk = blockSelf->_llm->set_config(configStr);
                ARLog(@"[LLM] Config set: %s (set_config=%s)", configStr.c_str(), inferConfigOk ? "true" : "false");

                blockSelf->_llm->reset();

                // 使用UTF-8安全的流缓冲区
                std::string accumulatedOutput;
                
                // 获取 atomic 指针以避免 lambda 中的 ivar 访问权限问题
                std::atomic<bool>* shouldStopPtr = &blockSelf->_shouldStop;
                
                Utf8SafeStreamBuffer::CallBack callback = [handler, &accumulatedOutput, shouldStopPtr, enableThinking](const char* str, size_t len) {
                    // Check for cancellation
                    if (shouldStopPtr->load()) {
                        return;
                    }

                    if (handler && str && len > 0) {
                        @autoreleasepool {
                            NSString *nsOutput = [[NSString alloc] initWithBytes:str
                                                                            length:len
                                                                          encoding:NSUTF8StringEncoding];
                            if (nsOutput && nsOutput.length > 0) {
                                accumulatedOutput.append([nsOutput UTF8String]);
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    handler(nsOutput);
                                });
                            } else {
                                NSMutableString *hex = [NSMutableString stringWithCapacity:(NSUInteger)len * 3];
                                size_t n = len > 16 ? 16 : len;
                                for (size_t i = 0; i < n; i++) {
                                    [hex appendFormat:@"%02X ", (unsigned char)str[i]];
                                }
                                NSLog(@"[LLM] Failed to decode bytes as UTF-8, len=%zu, first=%@", len, hex);
                            }
                        }
                    }
                };
                
                Utf8SafeStreamBuffer streambuf(callback);
                std::ostream os(&streambuf);
                
                // 将输入转换为 std::string
                std::string userInput = [input UTF8String];
                
                // Start inference
                ARLog(@"[LLM] Starting inference...");
                std::vector<ChatMessage> chat;
                chat.emplace_back(ChatMessage(
                    "system",
                    "You are a helpful assistant.\nUse the language requested by the user. If unspecified, reply in the same language as the user."));
                chat.emplace_back(ChatMessage("user", userInput));
                blockSelf->_llm->response(chat, &os, nullptr, (int)maxNewTokensForRun);
                
                if (!arLooksMeaningfulUtf8(accumulatedOutput)) {
                    std::string fullPrompt = userInput;
                    bool hasTemplate =
                        (fullPrompt.find("<|im_start|>") != std::string::npos) ||
                        (fullPrompt.find("<user>") != std::string::npos) ||
                        (fullPrompt.find("<chat_user>") != std::string::npos);
                    
                    if (!hasTemplate) {
                        fullPrompt = "<|im_start|>user\n" + fullPrompt + "<|im_end|>\n<|im_start|>assistant\n";
                    }
                    
                    ARLog(@"[LLM] Fallback prompt (first 100 chars):\n%.100s...", fullPrompt.c_str());
                    
                    std::vector<int> inputIds = blockSelf->_llm->tokenizer_encode(fullPrompt);
                    if (!inputIds.empty()) {
                        accumulatedOutput.clear();
                        blockSelf->_llm->reset();
                        blockSelf->_llm->response(inputIds, &os, nullptr, (int)maxNewTokensForRun);
                    }
                }
                
                // Flush any remaining data in stream buffer
                os.flush();

                auto context = blockSelf->_llm->getContext();
                if (context) {
                    ARLog(@"[LLM] Status=%d, output_tokens=%zu, gen_seq_len=%d, prefill_us=%lld, decode_us=%lld",
                          (int)context->status,
                          context->output_tokens.size(),
                          context->gen_seq_len,
                          (long long)context->prefill_us,
                          (long long)context->decode_us);
                    if (!context->output_tokens.empty()) {
                        NSMutableString *ids = [NSMutableString string];
                        size_t showIds = context->output_tokens.size() > 16 ? 16 : context->output_tokens.size();
                        for (size_t i = 0; i < showIds; i++) {
                            [ids appendFormat:@"%d ", context->output_tokens[i]];
                        }
                        ARLog(@"[LLM] First token ids (up to 16): %@", ids);
                        bool allSame = true;
                        int firstId = context->output_tokens[0];
                        for (size_t i = 1; i < context->output_tokens.size(); i++) {
                            if (context->output_tokens[i] != firstId) {
                                allSame = false;
                                break;
                            }
                        }
                        ARLog(@"[LLM] All tokens same: %s", allSame ? "true" : "false");
                    }
                    if (!context->output_tokens.empty()) {
                        std::string firstDecoded;
                        size_t show = context->output_tokens.size() > 8 ? 8 : context->output_tokens.size();
                        for (size_t i = 0; i < show; i++) {
                            firstDecoded += blockSelf->_llm->tokenizer_decode(context->output_tokens[i]);
                        }
                        ARLog(@"[LLM] First decoded (up to 8 tokens):\n%.200s", firstDecoded.c_str());
                    }
                } else {
                    ARLog(@"[LLM] Context is null after inference");
                }
                
                // Send end signal
                if (handler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        handler(@"<eop>");
                    });
                }
                
                ARLog(@"[LLM] Inference completed. Total output length: %zu bytes", accumulatedOutput.length());
                
            } @catch (NSException *exception) {
                NSLog(@"[LLMInferenceEngineWrapper] ObjC Exception during inference: %@", exception.reason);
                if (handler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        handler(@"<eop>");
                    });
                }
            }
        } catch (const std::exception& e) {
            std::string err = e.what();
            if (err == "Generation cancelled by user") {
                NSLog(@"[LLM] Inference cancelled by user");
            } else {
                NSLog(@"[LLM] C++ Exception during inference: %s", e.what());
            }
            // Even if cancelled or error, ensure we send eop to close the stream
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(@"<eop>");
                });
            }
        } catch (...) {
            NSLog(@"[LLM] Unknown C++ Exception during inference");
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(@"<eop>");
                });
            }
        }
        
        blockSelf->_isProcessing = false;
    });
}

- (void)clearHistory {
    std::lock_guard<std::mutex> lock(_historyMutex);
    _history.clear();
    _history.emplace_back(ChatMessage("system", "You are a helpful assistant."));
    if (_llm) {
        _llm->reset();
    }
    ARLog(@"[LLM] History cleared");
}

- (void)cancelInference {
    _shouldStop = true;
}

- (BOOL)isModelReady {
    std::lock_guard<std::mutex> lock(_mutex);
    return _llm != nullptr;
}

- (BOOL)isProcessing {
    return _isProcessing.load();
}

- (void)dealloc {
    std::lock_guard<std::mutex> lock(_mutex);
    _llm.reset();
}

@end
