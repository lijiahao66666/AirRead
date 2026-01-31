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
#import "LLMInferenceEngineWrapper.h"

// MNN Headers
#import <MNN/llm/llm.hpp>
using namespace MNN::Transformer;

// Stream buffer for capturing LLM output
class LlmStreamBuffer : public std::streambuf {
public:
    using CallBack = std::function<void(const char* str, size_t len)>;
    
    LlmStreamBuffer(CallBack callback) : callback_(callback) {}

protected:
    virtual std::streamsize xsputn(const char* s, std::streamsize n) override {
        if (callback_ && n > 0) {
            callback_(s, n);
        }
        return n;
    }

private:
    CallBack callback_ = nullptr;
};

@interface LLMInferenceEngineWrapper () {
    std::shared_ptr<Llm> _llm;
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
        
        // Configure LLM
        NSString *tempDirectory = NSTemporaryDirectory();
        std::string configStr = "{\"tmp_path\":\"" + std::string([tempDirectory UTF8String]) + "\", \"use_mmap\":true}";
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
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            // Buffer to handle incomplete UTF-8 characters
            static thread_local std::string utf8Buffer;
            
            LlmStreamBuffer::CallBack callback = [handler](const char* str, size_t len) {
                if (handler && str && len > 0) {
                    // Append to buffer
                    utf8Buffer.append(str, len);
                    
                    // Try to extract complete UTF-8 characters
                    size_t validLen = 0;
                    size_t i = 0;
                    while (i < utf8Buffer.length()) {
                        unsigned char c = utf8Buffer[i];
                        size_t charLen = 0;
                        
                        if ((c & 0x80) == 0) {
                            // ASCII (1 byte)
                            charLen = 1;
                        } else if ((c & 0xE0) == 0xC0) {
                            // 2-byte UTF-8
                            charLen = 2;
                        } else if ((c & 0xF0) == 0xE0) {
                            // 3-byte UTF-8 (Chinese characters)
                            charLen = 3;
                        } else if ((c & 0xF8) == 0xF0) {
                            // 4-byte UTF-8
                            charLen = 4;
                        } else {
                            // Invalid UTF-8, skip this byte
                            i++;
                            continue;
                        }
                        
                        // Check if we have enough bytes for this character
                        if (i + charLen <= utf8Buffer.length()) {
                            validLen = i + charLen;
                            i += charLen;
                        } else {
                            // Incomplete character, stop here
                            break;
                        }
                    }
                    
                    // Output valid UTF-8 string
                    if (validLen > 0) {
                        NSString *output = [[NSString alloc] initWithBytes:utf8Buffer.c_str()
                                                                    length:validLen
                                                                  encoding:NSUTF8StringEncoding];
                        if (output) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                handler(output);
                            });
                        }
                        // Remove processed bytes from buffer
                        utf8Buffer.erase(0, validLen);
                    }
                }
            };
            
            LlmStreamBuffer streambuf(callback);
            std::ostream os(&streambuf);
            
            // Process input
            std::string inputStr = [input UTF8String];
            _llm->response(inputStr, &os, "<eop>");
            
        } @catch (NSException *exception) {
            NSLog(@"[LLMInferenceEngineWrapper] Exception during inference: %@", exception.reason);
        }
        
        _isProcessing = false;
    });
}

- (void)cancelInference {
    _shouldStop = true;
    // Note: Actual cancellation depends on MNN LLM's support for stopping inference
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
