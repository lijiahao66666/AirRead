Pod::Spec.new do |s|
  s.name             = 'LocalMNN'
  s.version          = '0.0.1'
  s.summary          = 'Local MNN Framework with LLM support'
  s.homepage         = 'https://github.com/alibaba/MNN'
  s.license          = { :type => 'Apache 2.0' }
  s.author           = { 'Alibaba' => 'mnn@alibaba-inc.com' }
  s.source           = { :git => 'https://github.com/alibaba/MNN.git', :tag => s.version.to_s }
  s.ios.deployment_target = '14.0'
  
  # 框架
  s.vendored_frameworks = 'Frameworks/MNN.xcframework'
  
  # 源文件
  s.source_files = 'Runner/LLMInferenceEngineWrapper.{h,mm}', 'Runner/MnnLlmBridge.{h,mm}'
  
  # 依赖
  s.frameworks = 'Foundation', 'Metal', 'MetalPerformanceShaders'
  s.libraries = 'c++'
  
  s.requires_arc = true
  
  # C++ 设置
  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -std=c++17'
  }

  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64'
  }
end
