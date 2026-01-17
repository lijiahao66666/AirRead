cmake_minimum_required(VERSION 3.4.1)

add_library(mnn_bridge SHARED mnn_bridge.cpp)

set(MNN_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/mnn/include)
set(MNN_LIB_DIR ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
set(MNN_LIB_PATH ${MNN_LIB_DIR}/libMNN.so)
set(MNN_EXPRESS_LIB_PATH ${MNN_LIB_DIR}/libMNN_Express.so)
set(MNN_LLM_LIB_PATH ${MNN_LIB_DIR}/libllm.so)
set(MNN_LLM_HEADER ${MNN_INCLUDE_DIR}/MNN/llm/llm.hpp)

if (EXISTS "${MNN_LIB_PATH}" AND EXISTS "${MNN_EXPRESS_LIB_PATH}" AND EXISTS "${MNN_LLM_LIB_PATH}" AND EXISTS "${MNN_LLM_HEADER}")
    add_library(MNN SHARED IMPORTED)
    set_target_properties(MNN PROPERTIES IMPORTED_LOCATION ${MNN_LIB_PATH})

    add_library(MNN_Express SHARED IMPORTED)
    set_target_properties(MNN_Express PROPERTIES IMPORTED_LOCATION ${MNN_EXPRESS_LIB_PATH})

    add_library(llm SHARED IMPORTED)
    set_target_properties(llm PROPERTIES IMPORTED_LOCATION ${MNN_LLM_LIB_PATH})

    target_include_directories(mnn_bridge PRIVATE ${MNN_INCLUDE_DIR})
    target_compile_definitions(mnn_bridge PRIVATE ENABLE_MNN=1)
    target_link_libraries(mnn_bridge MNN MNN_Express llm android log)
else()
    target_link_libraries(mnn_bridge android log)
endif()
