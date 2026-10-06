# Combines the WebRTC.framework of each iOS slice build into
# WebRTC.xcframework: one framework per environment (device, simulator), the
# slices of an environment merged with lipo. Run by the WebRTC_xcframework
# target in webrtc-min's CMakeLists.txt:
#
#   cmake -DOUTPUT=<path>/WebRTC.xcframework \
#     -DSLICES=<environment>=<slice build dir>|... -P ios_xcframework.cmake
cmake_minimum_required(VERSION 3.22)

string(REPLACE "|" ";" SLICES "${SLICES}")
set(work ${OUTPUT}.slices)
file(REMOVE_RECURSE ${OUTPUT} ${work})

set(environments)
foreach(slice IN LISTS SLICES)
  string(REPLACE "=" ";" parts "${slice}")
  list(GET parts 0 environment)
  list(GET parts 1 dir)
  # webrtc/sdk/WebRTC.framework with Ninja, webrtc/sdk/<config>-<sdk>/ with
  # Xcode.
  file(GLOB framework LIST_DIRECTORIES true
    ${dir}/webrtc/sdk/WebRTC.framework ${dir}/webrtc/sdk/*/WebRTC.framework)
  if(NOT framework)
    message(FATAL_ERROR "No WebRTC.framework in ${dir}/webrtc/sdk")
  endif()
  list(APPEND frameworks_${environment} ${framework})
  list(APPEND environments ${environment})
endforeach()
list(REMOVE_DUPLICATES environments)

set(args)
foreach(environment IN LISTS environments)
  set(frameworks ${frameworks_${environment}})
  list(GET frameworks 0 first)
  file(COPY ${first} DESTINATION ${work}/${environment})
  set(merged ${work}/${environment}/WebRTC.framework)
  list(LENGTH frameworks n)
  if(n GREATER 1)
    set(binaries)
    foreach(framework IN LISTS frameworks)
      list(APPEND binaries ${framework}/WebRTC)
    endforeach()
    execute_process(COMMAND lipo -create ${binaries} -output ${merged}/WebRTC
      COMMAND_ERROR_IS_FATAL ANY)
  endif()
  list(APPEND args -framework ${merged})
endforeach()

execute_process(
  COMMAND xcodebuild -create-xcframework ${args} -output ${OUTPUT}
  COMMAND_ERROR_IS_FATAL ANY)
file(REMOVE_RECURSE ${work})
