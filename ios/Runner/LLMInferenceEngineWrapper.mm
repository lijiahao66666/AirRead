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
#import "LLMInferenceEngineWrapper.h"

// MNN Headers
#import <MNN/llm/llm.hpp>
using namespace MNN::Transformer;

using ChatMessage = std::pair<std::string, std::string>;

// UTF-8 安全流缓冲区 - 累积字节直到形成完整UTF-8字符
class Utf8SafeStreamBuffer : public std::streambuf {
public:
    using CallBack = std::function<void(const char* str, size_t len)>;
    
    Utf8SafeStreamBuffer(CallBack callback) : callback_(callback) {
        byteBuffer_.reserve(256);
    }
    
    ~Utf8SafeStreamBuffer() {
        flushRemaining();
    }

protected:
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
                    i++;
                }
            } else {
                // 不完整的字符，停止处理
                break;
            }
        }
        
        // 发送完整的UTF-8字符串
        if (!outputStr.empty() && callback_) {
            callback_(outputStr.c_str(), outputStr.size());
        }
        
        // 移除已处理的数据
        if (i > 0) {
            byteBuffer_.erase(0, i);
        }
    }
    
    size_t getUtf8CharLength(unsigned char firstByte) {
        if ((firstByte & 0x80) == 0) {
            return 1;  // ASCII
        } else if ((firstByte & 0xE0) == 0xC0) {
            return 2;  // 2-byte UTF-8
        } else if ((firstByte & 0xF0) == 0xE0) {
            return 3;  // 3-byte UTF-8 (中文)
        } else if ((firstByte & 0xF8) == 0xF0) {
            return 4;  // 4-byte UTF-8
        }
        return 1;  // 无效字节，按单字节处理
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
        
        // Configure LLM - 针对Qwen优化配置
        NSString *tempDirectory = NSTemporaryDirectory();
        std::string configStr = "{"
            "\"tmp_path\":\"" + std::string([tempDirectory UTF8String]) + "\","
            "\"use_mmap\":true,"
            "\"reuse_kv\":false,"  // 禁用KV复用避免上下文混乱
            "\"max_new_tokens\":512"  // 限制最大token数避免内存问题
            "}";
        _llm->set_config(configStr);
        
        // Load model
        _llm->load();
        
        NSLog(@"[LLMInferenceEngineWrapper] Model loaded successfully from %@", _modelPath);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[LLMInferenceEngineWrapper] Exception during model loading: %@", exception.reason);
        return NO;
    }
}

- (void)processInput:(NSString *)input
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
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        @try {
            // 使用UTF-8安全的流缓冲区
            Utf8SafeStreamBuffer::CallBack callback = [handler](const char* str, size_t len) {
                if (handler && str && len > 0) {
                    @autoreleasepool {
                        NSString *nsOutput = [[NSString alloc] initWithBytes:str
                                                                        length:len
                                                                      encoding:NSUTF8StringEncoding];
                        if (nsOutput && nsOutput.length > 0) {
                            NSLog(@"[LLM] Output: '%@'", nsOutput);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                handler(nsOutput);
                            });
                        }
                    }
                }
            };
            
            Utf8SafeStreamBuffer streambuf(callback);
            std::ostream os(&streambuf);
            
            // Thread-safe history management
            {
                std::lock_guard<std::mutex> lock(blockSelf->_historyMutex);
                blockSelf->_history.emplace_back(ChatMessage("user", [input UTF8String]));
            }
            
            // Reset stop flag before starting inference
            blockSelf->_shouldStop = false;
            
            // Debug information for prompt
            std::string prompt_debug = "";
            for (const auto& msg : blockSelf->_history) {
                prompt_debug += msg.first + ": " + msg.second + "\n";
            }
            NSLog(@"[LLM] Prompt:\n%s", prompt_debug.c_str());
            
            // Start inference - 使用简单的一次性生成避免复杂的token-by-token控制
            // 对于Qwen模型，使用简单的response调用更稳定
            blockSelf->_llm->response(blockSelf->_history, &os, "<eop>", 512);
            
            // Send end signal
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(@"<eop>");
                });
            }
            
            NSLog(@"[LLM] Inference completed");
            
        } @catch (NSException *exception) {
            NSLog(@"[LLMInferenceEngineWrapper] Exception during inference: %@", exception.reason);
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
    NSLog(@"[LLM] History cleared");
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
