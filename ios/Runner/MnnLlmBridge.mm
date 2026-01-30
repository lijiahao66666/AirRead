#import "MnnLlmBridge.h"
#import <TargetConditionals.h>
#import <sys/sysctl.h>
#import <mach/mach.h>

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

// Memory management constants
static const unsigned long long kMinFreeMemoryRequired = 500 * 1024 * 1024; // 500MB minimum free memory
static const unsigned long long kMemorySafetyMultiplier = 2; // Model size * 2 for safety
#endif

@implementation MnnLlmBridge

+ (BOOL)isAvailable {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

+ (unsigned long long)getAvailableMemory {
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t infoCount = HOST_VM_INFO64_COUNT;
    kern_return_t kernReturn = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmStats, &infoCount);
    
    if (kernReturn != KERN_SUCCESS) {
        return 0;
    }
    
    unsigned long long freeMemory = (unsigned long long)vmStats.free_count * (unsigned long long)vm_page_size;
    unsigned long long inactiveMemory = (unsigned long long)vmStats.inactive_count * (unsigned long long)vm_page_size;
    
    return freeMemory + inactiveMemory;
}

+ (unsigned long long)getTotalMemory {
    unsigned long long totalMemory = 0;
    size_t size = sizeof(totalMemory);
    int mib[2] = { CTL_HW, HW_MEMSIZE };
    sysctl(mib, 2, &totalMemory, &size, NULL, 0);
    return totalMemory;
}

+ (BOOL)hasEnoughMemoryForModel:(NSString *)modelPath {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:modelPath error:nil];
    unsigned long long modelSize = [attributes fileSize];
    
    if (modelSize == 0) {
        // Try to calculate from directory
        modelSize = [self calculateDirectorySize:modelPath];
    }
    
    unsigned long long availableMemory = [self getAvailableMemory];
    unsigned long long requiredMemory = modelSize * kMemorySafetyMultiplier + kMinFreeMemoryRequired;
    
    NSLog(@"[MnnLlmBridge] Model size: %llu MB, Available: %llu MB, Required: %llu MB",
          modelSize / (1024 * 1024), availableMemory / (1024 * 1024), requiredMemory / (1024 * 1024));
    
    return availableMemory >= requiredMemory;
#endif
}

+ (unsigned long long)calculateDirectorySize:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:path];
    NSString *file;
    while ((file = [enumerator nextObject])) {
        NSString *filePath = [path stringByAppendingPathComponent:file];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:filePath error:nil];
        if (attributes) {
            totalSize += [attributes fileSize];
        }
    }
    
    return totalSize;
}

+ (BOOL)loadModel:(NSString*)path error:(NSError**)error {
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
        std::string configPath = [path UTF8String];
        
        // Check if file exists
        std::ifstream file(configPath);
        if (!file.good()) {
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1001
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Config file not found: %@", path]}];
            }
            return NO;
        }
        file.close();
        
        // Check memory availability before loading
        NSString *modelDir = [path stringByDeletingLastPathComponent];
        if (![self hasEnoughMemoryForModel:modelDir]) {
            unsigned long long availableMemory = [self getAvailableMemory];
            unsigned long long totalMemory = [self getTotalMemory];
            
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1011
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"设备内存不足。可用: %.1f MB, 总共: %.1f MB。请关闭其他应用后重试。", 
                                                                                availableMemory / (1024.0 * 1024.0), 
                                                                                totalMemory / (1024.0 * 1024.0)]}];
            }
            return NO;
        }
        
        // Destroy existing instance if any to free memory
        if (g_llmInstance) {
            NSLog(@"[MnnLlmBridge] Destroying existing LLM instance to free memory");
            MNN::Transformer::Llm::destroy(g_llmInstance.release());
            // Give system time to reclaim memory
            [NSThread sleepForTimeInterval:0.1];
        }
        
        // Create new LLM instance
        NSLog(@"[MnnLlmBridge] Creating LLM instance...");
        MNN::Transformer::Llm* llm = MNN::Transformer::Llm::createLLM(configPath);
        if (!llm) {
            if (error) {
                *error = [NSError errorWithDomain:@"MnnLlmBridge"
                                             code:1002
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create LLM instance"}];
            }
            return NO;
        }
        
        // Load the model with memory optimization
        NSLog(@"[MnnLlmBridge] Loading model...");
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
        
        NSLog(@"[MnnLlmBridge] Model loaded successfully");
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

+ (NSString*)getConfig:(NSError**)error {
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

+ (void)cancelStream {
#if !TARGET_OS_SIMULATOR
    g_isStreaming = NO;
#endif
}

+ (nullable NSString*)generate:(NSString*)prompt
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

+ (void)generateStream:(NSString*)prompt
          maxNewTokens:(int)maxNewTokens
        maxInputTokens:(int)maxInputTokens
           temperature:(double)temperature
                  topP:(double)topP
                  topK:(int)topK
                  minP:(double)minP
       presencePenalty:(double)presencePenalty
     repetitionPenalty:(double)repetitionPenalty
        enableThinking:(int)enableThinking
               onChunk:(void (^)(NSString* _Nullable chunk))onChunk
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
