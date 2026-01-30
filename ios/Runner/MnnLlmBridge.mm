#import "MnnLlmBridge.h"
#import <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#import <MNN/llm/llm.hpp>
#import <MNN/MNNDefine.h>
#import <fstream>
#import <sstream>
#import <iostream>
#import <memory>
#import <mutex>

// Global LLM instance management
static std::unique_ptr<MNN::Transformer::Llm> g_llmInstance;
static std::mutex g_llmMutex;
static BOOL g_isStreaming = NO;
#endif

@implementation MnnLlmBridge

+ (BOOL)isAvailable {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

+ (BOOL)initializeWithModelPath:(NSString*)modelPath error:(NSError**)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                     code:1100
                                 userInfo:@{NSLocalizedDescriptionKey: @"本地推理在模拟器上不可用"}];
    }
    return NO;
#else
    std::lock_guard<std::mutex> lock(g_llmMutex);
    
    @try {
        // Convert NSString to std::string
        std::string configPath = [modelPath UTF8String];
        
        // Check if file exists
        std::ifstream file(configPath);
        if (!file.good()) {
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1001
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Config file not found: %@", modelPath]}];
            }
            return NO;
        }
        file.close();
        
        // Destroy existing instance if any
        if (g_llmInstance) {
            MNN::Transformer::Llm::destroy(g_llmInstance.release());
        }
        
        // Create new LLM instance
        MNN::Transformer::Llm* llm = MNN::Transformer::Llm::createLLM(configPath);
        if (!llm) {
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1002
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create LLM instance"}];
    }
            return NO;
        }
        
        // Load the model
        bool loaded = llm->load();
        if (!loaded) {
            MNN::Transformer::Llm::destroy(llm);
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1003
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to load model"}];
            }
            return NO;
        }
        
        g_llmInstance.reset(llm);
        return YES;
        
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
        }
        return NO;
    }
#endif
}

+ (NSString*)dumpConfigWithError:(NSError**)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                     code:1101
                                 userInfo:@{NSLocalizedDescriptionKey: @"本地推理在模拟器上不可用"}];
    }
    return nil;
#else
    std::lock_guard<std::mutex> lock(g_llmMutex);
    
    if (!g_llmInstance) {
        if (error) {
            *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey: @"LLM not initialized"}];
        }
        return nil;
    }
    
    @try {
        std::string config = g_llmInstance->dump_config();
        return [NSString stringWithUTF8String:config.c_str()];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                         code:1006
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
        }
        return nil;
    }
#endif
}

+ (void)cancelCurrentStream {
#if !TARGET_OS_SIMULATOR
    g_isStreaming = NO;
#endif
}

+ (nullable NSString*)chatOnce:(NSString*)prompt
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
    
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                     code:1102
                                 userInfo:@{NSLocalizedDescriptionKey: @"本地推理在模拟器上不可用"}];
    }
    return nil;
#else
    std::lock_guard<std::mutex> lock(g_llmMutex);
    
    if (!g_llmInstance) {
        if (error) {
            *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                         code:1007
                                     userInfo:@{NSLocalizedDescriptionKey: @"LLM not initialized"}];
        }
        return nil;
    }
    
    @try {
        std::string userPrompt = [prompt UTF8String];
        
        // Use stringstream to capture output
        std::ostringstream oss;
        
        // Set generation parameters if needed
        // Note: MNN LLM API may vary, adjust according to actual API
        
        // Call response method
        g_llmInstance->response(userPrompt, &oss, nullptr, maxNewTokens);
        
        std::string result = oss.str();
        return [NSString stringWithUTF8String:result.c_str()];
        
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                         code:1008
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
        }
        return nil;
    }
#endif
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
    
#if TARGET_OS_SIMULATOR
    if (onDone) {
        NSError *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1103
                                         userInfo:@{NSLocalizedDescriptionKey: @"本地推理在模拟器上不可用"}];
        onDone(error);
    }
    return;
#else
    std::lock_guard<std::mutex> lock(g_llmMutex);
    
    if (!g_llmInstance) {
        if (onDone) {
            NSError *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                                 code:1009
                                             userInfo:@{NSLocalizedDescriptionKey: @"LLM not initialized"}];
            onDone(error);
        }
        return;
    }
    
    g_isStreaming = YES;
    
    @try {
        std::string userPrompt = [prompt UTF8String];
        
        // Custom stream buffer to capture output chunk by chunk
        class ChunkedStreamBuf : public std::streambuf {
        public:
            ChunkedStreamBuf(void (^chunkHandler)(NSString*)) : chunkHandler_(chunkHandler) {}
            
        protected:
            virtual int_type overflow(int_type c) override {
                if (c != traits_type::eof()) {
                    buffer_ += static_cast<char>(c);
                    if (c == '\n' || buffer_.length() >= 4) {
                        flushBuffer();
                    }
                }
                return c;
            }
            
            virtual std::streamsize xsputn(const char* s, std::streamsize n) override {
                buffer_.append(s, n);
                if (buffer_.length() >= 4) {
                    flushBuffer();
                }
                return n;
            }
            
            void flushBuffer() {
                if (!buffer_.empty() && chunkHandler_) {
                    NSString *chunk = [NSString stringWithUTF8String:buffer_.c_str()];
                    if (chunk) {
                        chunkHandler_(chunk);
                    }
                    buffer_.clear();
                }
            }
            
        private:
            void (^chunkHandler_)(NSString*);
            std::string buffer_;
        };
        
        ChunkedStreamBuf streamBuf(onChunk);
        std::ostream oss(&streamBuf);
        
        // Call response method
        g_llmInstance->response(userPrompt, &oss, nullptr, maxNewTokens);
        
        // Flush remaining content
        streamBuf.pubsync();
        
        if (onDone) {
            onDone(nil);
        }
        
    } @catch (NSException *exception) {
        if (onDone) {
            NSError *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                                 code:1010
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
            onDone(error);
        }
    }
    
    g_isStreaming = NO;
#endif
}

@end
