cmake_minimum_required(VERSION 3.18.0)

project(WavesAudioDriver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CODESIGN_ID "" CACHE STRING "Codesign ID")
set(LIBASPL_GIT_TAG "v3.1.2" CACHE STRING "libASPL git ref")

set(DRIVER_NAME "WavesAudio")
set(DRIVER_VERSION "0.1.0")
set(DRIVER_COPYRIGHT "Copyright (c) Jonathan Reed")
set(DRIVER_IDENTIFIER "com.jonathanreed.waves.audio-driver")
set(DRIVER_UID "2C674840-5132-4A18-B65C-4FF257CD6A26")
set(DRIVER_ENTRYPOINT "WavesEntryPoint")

include(ExternalProject)

set(LIBASPL_TARGET WavesAudio_libASPL)
ExternalProject_Add(${LIBASPL_TARGET}
  GIT_REPOSITORY https://github.com/gavv/libASPL.git
  GIT_TAG ${LIBASPL_GIT_TAG}
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-build
  INSTALL_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix
  CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
  LOG_DOWNLOAD YES
  LOG_CONFIGURE YES
  LOG_BUILD YES
  LOG_INSTALL YES
)

add_library(${DRIVER_NAME} MODULE
  Driver.cpp
)

add_dependencies(${DRIVER_NAME} ${LIBASPL_TARGET})
target_include_directories(${DRIVER_NAME}
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/include
)
target_link_libraries(${DRIVER_NAME}
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/lib/libASPL.a
)

find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
find_library(LIB_SystemConfiguration SystemConfiguration REQUIRED)

target_link_libraries(${DRIVER_NAME}
  PRIVATE ${LIB_CoreFoundation}
  PRIVATE ${LIB_SystemConfiguration}
)

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
)

if(NOT CODESIGN_ID STREQUAL "")
  add_custom_command(
    TARGET ${DRIVER_NAME}
    POST_BUILD
    COMMENT "Signing ${DRIVER_NAME}.driver with ID ${CODESIGN_ID}"
    VERBATIM
    COMMAND
      codesign --force -s "${CODESIGN_ID}"
        "${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver"
  )
endif()
