cmake_minimum_required(VERSION 3.16)
project(xdm_media LANGUAGES C CXX)

# One Ninja compile/link process per build tree, including when invoked by hvigor.
# The outer build coordinator must also serialize different ABI build trees.
set_property(GLOBAL PROPERTY JOB_POOLS xdm_native=1)
set(CMAKE_JOB_POOL_COMPILE xdm_native)
set(CMAKE_JOB_POOL_LINK xdm_native)

if(NOT OHOS_ARCH STREQUAL "arm64-v8a" AND NOT OHOS_ARCH STREQUAL "x86_64")
  message(FATAL_ERROR "xdm_media requires the OHOS arm64-v8a or x86_64 toolchain")
endif()

set(THIRDPARTY "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/${OHOS_ARCH}")
foreach(COMPONENT avformat avcodec swresample avutil mp3lame)
  if(NOT EXISTS "${THIRDPARTY}/lib/lib${COMPONENT}.a")
    message(FATAL_ERROR "Missing verified ${OHOS_ARCH} lib${COMPONENT}.a; see tools/native/README.md")
  endif()
  add_library(xdm_${COMPONENT} STATIC IMPORTED)
  set_target_properties(xdm_${COMPONENT} PROPERTIES IMPORTED_LOCATION "${THIRDPARTY}/lib/lib${COMPONENT}.a")
endforeach()

add_library(xdm_media_core STATIC media/MediaJob.cpp media/MediaProcessor.cpp)
set_target_properties(xdm_media_core PROPERTIES POSITION_INDEPENDENT_CODE ON CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
target_include_directories(xdm_media_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${THIRDPARTY}/include")
target_compile_definitions(xdm_media_core PRIVATE XDM_MEDIA_ABI="${OHOS_ARCH}")
target_compile_options(xdm_media_core PRIVATE -Wall -Wextra -Werror -Wno-error=unused-command-line-argument -fvisibility=hidden)
target_link_libraries(xdm_media_core PUBLIC
  -Wl,--start-group xdm_avformat xdm_avcodec xdm_swresample xdm_avutil xdm_mp3lame -Wl,--end-group m)

add_library(xdm_media SHARED napi_init.cpp)
set_target_properties(xdm_media PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
target_compile_options(xdm_media PRIVATE -Wall -Wextra -Werror -Wno-error=unused-command-line-argument -fvisibility=hidden)
target_link_options(xdm_media PRIVATE -Wl,--exclude-libs,ALL -Wl,--no-undefined)
target_link_libraries(xdm_media PRIVATE xdm_media_core libace_napi.z.so)

option(XDM_MEDIA_BUILD_RUNNER "Build the standalone target validation executable" OFF)
if(XDM_MEDIA_BUILD_RUNNER)
  add_executable(xdm_media_runner "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tools/native/media_runner.cpp")
  set_target_properties(xdm_media_runner PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
  target_compile_options(xdm_media_runner PRIVATE -Wall -Wextra -Werror -Wno-error=unused-command-line-argument)
  target_link_libraries(xdm_media_runner PRIVATE xdm_media_core)
endif()
