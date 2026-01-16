cmake_minimum_required(VERSION 3.4.1)

# Configure MNN Library Path
# Please create 'android/libs/mnn' directory and put libMNN.so, libMNN_LLM.so and headers there.
# Structure:
# android/libs/mnn/include/ (MNN headers)
# android/libs/mnn/libs/arm64-v8a/ (libMNN.so, libMNN_LLM.so)

set(MNN_DIR ${CMAKE_SOURCE_DIR}/../../../../libs/mnn)

# If you haven't set up MNN yet, these lines might cause CMake error.
# You can comment them out until you put the libraries in place.

# add_library(MNN SHARED IMPORTED)
# set_target_properties(MNN PROPERTIES IMPORTED_LOCATION ${MNN_DIR}/libs/${ANDROID_ABI}/libMNN.so)

# add_library(MNN_LLM SHARED IMPORTED)
# set_target_properties(MNN_LLM PROPERTIES IMPORTED_LOCATION ${MNN_DIR}/libs/${ANDROID_ABI}/libMNN_LLM.so)

# Include directories
# include_directories(${MNN_DIR}/include)

add_library(mnn_bridge SHARED mnn_bridge.cpp)

# Link libraries
# Uncomment MNN and MNN_LLM when ready
target_link_libraries(mnn_bridge 
    # MNN 
    # MNN_LLM 
    android 
    log
)
