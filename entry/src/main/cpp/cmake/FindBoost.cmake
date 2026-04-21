if(NOT DEFINED OFFHAND_BOOST_ROOT)
  set(Boost_FOUND FALSE)
  return()
endif()

set(Boost_FOUND TRUE)
set(Boost_INCLUDE_DIRS "${OFFHAND_BOOST_ROOT}")
set(Boost_LIBRARY_DIRS "")
set(Boost_LIBRARIES "")
set(Boost_VERSION_STRING "1.88.0")
set(Boost_VERSION 108800)

if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${OFFHAND_BOOST_ROOT}")
endif()
