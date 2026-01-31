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
                    NSLog(@"[Utf8SafeStreamBuffer] Invalid UTF-8 sequence at %zu, byte: 0x%02X", i, c);
                    i++;
                }
            } else {
                // 不完整的字符，停止处理，保留到下一次
                break;
            }
        }
        
        // 发送完整的UTF-8字符串
        if (!outputStr.empty() && callback_) {
            NSLog(@"[Utf8SafeStreamBuffer] Sending %zu bytes", outputStr.size());
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
            NSLog(@"[Utf8SafeStreamBuffer] Flushing remaining %zu bytes", byteBuffer_.size());
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
        
        // Configure LLM - 使用 config.json 中的配置，不再硬编码
        // MNN 会自动从 config.json 和 llm_config.json 读取配置
        // NSString *tempDirectory = NSTemporaryDirectory();
        // std::string configStr = "{"
        //     "\"tmp_path\":\"" + std::string([tempDirectory UTF8String]) + "\","
        //     "\"use_mmap\":true,"
        //     "\"reuse_kv\":true,"
        //     "\"max_new_tokens\":512,"
        //     "\"thread_num\":4"
        //     "}";
        // _llm->set_config(configStr);
        NSLog(@"[LLMInferenceEngineWrapper] Using config from config.json");
        
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
            std::string accumulatedOutput;
            
            Utf8SafeStreamBuffer::CallBack callback = [handler, &accumulatedOutput](const char* str, size_t len) {
                if (handler && str && len > 0) {
                    @autoreleasepool {
                        // 记录原始字节用于调试
                        NSMutableString *hexDebug = [NSMutableString stringWithString:@"Bytes: "];
                        for (size_t i = 0; i < std::min(len, (size_t)16); i++) {
                            [hexDebug appendFormat:@"%02X ", (unsigned char)str[i]];
                        }
                        NSLog(@"[LLM] Raw %s", hexDebug.UTF8String);
                        
                        NSString *nsOutput = [[NSString alloc] initWithBytes:str
                                                                        length:len
                                                                      encoding:NSUTF8StringEncoding];
                        if (nsOutput && nsOutput.length > 0) {
                            accumulatedOutput.append([nsOutput UTF8String]);
                            NSLog(@"[LLM] Output chunk (%zu bytes): '%@'", len, nsOutput);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                handler(nsOutput);
                            });
                        } else {
                            NSLog(@"[LLM] Failed to decode bytes as UTF-8, len=%zu", len);
                        }
                    }
                }
            };
            
            Utf8SafeStreamBuffer streambuf(callback);
            std::ostream os(&streambuf);
            
            // 将输入转换为 std::string
            std::string userInput = [input UTF8String];
            
            // Debug information for prompt
            NSLog(@"[LLM] Input prompt:\n%s", userInput.c_str());
            
            // Start inference - 使用直接的 prompt 字符串而不是 history
            NSLog(@"[LLM] Starting inference...");
            
            // 使用 response 方法直接传入 prompt 字符串
            blockSelf->_llm->response(userInput, &os, "<eop>", 512);
            
            // Flush any remaining data in stream buffer
            os.flush();
            
            // Send end signal
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(@"<eop>");
                });
            }
            
            NSLog(@"[LLM] Inference completed. Total output length: %zu bytes", accumulatedOutput.length());
            
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
