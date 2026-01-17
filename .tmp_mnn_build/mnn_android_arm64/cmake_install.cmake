# Install script for directory: C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "C:/Program Files (x86)/MNN")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "C:/Users/28679/AppData/Local/Android/Sdk/ndk/25.1.8937393/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-objdump.exe")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include" TYPE DIRECTORY FILES "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/transformers/llm/engine/include/" FILES_MATCHING REGEX "/[^/]*\\.hpp$")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/MNN" TYPE FILE FILES
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/MNNDefine.h"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/Interpreter.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/HalideRuntime.h"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/Tensor.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/ErrorCode.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/ImageProcess.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/Matrix.h"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/Rect.h"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/MNNForwardType.h"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/AutoTime.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/MNNSharedContext.h"
    )
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/MNN/expr" TYPE FILE FILES
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/Expr.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/ExprCreator.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/MathOp.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/NeuralNetWorkOp.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/Optimizer.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/Executor.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/Module.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/NeuralNetWorkOp.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/ExecutorScope.hpp"
    "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/MNN/include/MNN/expr/Scope.hpp"
    )
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so"
         RPATH "")
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/mnn_android_arm64/libMNN.so")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "C:/Users/28679/AppData/Local/Android/Sdk/ndk/25.1.8937393/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libMNN.so")
    endif()
  endif()
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.
  include("C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/mnn_android_arm64/express/cmake_install.cmake")
  include("C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/mnn_android_arm64/tools/audio/cmake_install.cmake")
  include("C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/mnn_android_arm64/tools/converter/cmake_install.cmake")

endif()

if(CMAKE_INSTALL_COMPONENT)
  set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
file(WRITE "C:/Users/28679/traeProjects/AirRead/.tmp_mnn_build/mnn_android_arm64/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
