if(TARGET libopencc)
  set(Opencc_FOUND TRUE)
  set(Opencc_INCLUDE_PATH
    "${OFFHAND_LIBRIME_ROOT}/deps/opencc/include"
    "${OFFHAND_OPENCC_BINARY_DIR}/src")
  set(Opencc_LIBRARY libopencc)
else()
  set(Opencc_FOUND FALSE)
endif()
