cmake_minimum_required(VERSION 3.4.1)

# 设置 MNN 路径
set(MNN_ROOT "c:/Users/28679/traeProjects/MNN")
set(MNN_INCLUDE_DIR ${MNN_ROOT}/include)
set(MNN_LIB_DIR ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
set(MNN_LIB_PATH ${MNN_LIB_DIR}/libMNN.so)

# 检查 MNN 库是否存在
if (EXISTS "${MNN_LIB_PATH}")
    message(STATUS "MNN libraries found, building with MNN support")
    
    # 检查 LLM 库是否存在
    set(LLM_LIB_PATH ${MNN_LIB_DIR}/libllm.so)
    
    if (EXISTS "${LLM_LIB_PATH}")
        message(STATUS "LLM library found, building with full MNN LLM support")
        
        # 创建 mnn_bridge 库（完整版本，使用 LLM 引擎）
        add_library(mnn_bridge SHARED 
            mnn_bridge_real.cpp
        )
        
        # 添加 MNN 库
        add_library(MNN SHARED IMPORTED)
        set_target_properties(MNN PROPERTIES IMPORTED_LOCATION ${MNN_LIB_PATH})
        
        # 添加 LLM 库
        add_library(llm SHARED IMPORTED)
        set_target_properties(llm PROPERTIES IMPORTED_LOCATION ${LLM_LIB_PATH})
        
        # 设置包含目录
        target_include_directories(mnn_bridge PRIVATE 
            ${MNN_INCLUDE_DIR}
            ${CMAKE_SOURCE_DIR}/include
        )
        
        # 添加编译定义
        target_compile_definitions(mnn_bridge PRIVATE 
            ENABLE_MNN=1
        )
        
        # 链接库
        target_link_libraries(mnn_bridge 
            llm
            MNN 
            android 
            log
        )
        
        # 添加 C++17 支持
        target_compile_options(mnn_bridge PRIVATE -std=c++17)
    else()
        message(STATUS "LLM library not found, building with simple MNN support")
        
        # 创建 mnn_bridge 库（简化版本，不依赖 LLM 引擎）
        add_library(mnn_bridge SHARED 
            mnn_bridge_simple.cpp
        )
        
        # 添加 MNN 库
        add_library(MNN SHARED IMPORTED)
        set_target_properties(MNN PROPERTIES IMPORTED_LOCATION ${MNN_LIB_PATH})
        
        # 设置包含目录
        target_include_directories(mnn_bridge PRIVATE 
            ${MNN_INCLUDE_DIR}
        )
        
        # 添加编译定义
        target_compile_definitions(mnn_bridge PRIVATE 
            ENABLE_MNN=1
        )
        
        # 链接库
        target_link_libraries(mnn_bridge 
            MNN 
            android 
            log
        )
        
        # 添加 C++17 支持
        target_compile_options(mnn_bridge PRIVATE -std=c++17)
    endif()
else()
    message(STATUS "MNN libraries not found, building mock implementation")
    add_library(mnn_bridge SHARED mnn_bridge.cpp)
    target_link_libraries(mnn_bridge android log)
endif()
