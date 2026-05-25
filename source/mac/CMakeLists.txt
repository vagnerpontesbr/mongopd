cmake_minimum_required(VERSION 3.16)
project(mongopd VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# mongo-c-driver 1.x uses libmongoc-1.0 / libbson-1.0; 2.x uses mongoc / bson.
# Try 2.x first, fall back to 1.x for backwards compatibility.
find_package(mongoc QUIET)
if(mongoc_FOUND)
    set(MONGOC_LIBRARIES  mongoc::mongoc)
    set(MONGOC_INCLUDE_DIRS "")
    set(MONGOC_DEFINITIONS "")
    set(BSON_LIBRARIES    bson::bson)
    set(BSON_INCLUDE_DIRS "")
    set(BSON_DEFINITIONS  "")
    find_package(bson REQUIRED)
    message(STATUS "Using mongo-c-driver 2.x (mongoc::mongoc)")
else()
    find_package(libmongoc-1.0 REQUIRED)
    find_package(libbson-1.0   REQUIRED)
    message(STATUS "Using mongo-c-driver 1.x (MONGOC_LIBRARIES=${MONGOC_LIBRARIES})")
endif()

set(SOURCES
    src/main.c
    src/args.c
    src/connection.c
    src/output.c
    src/bsonutil.c
    src/cmd_locks.c
    src/cmd_wlocks.c
    src/cmd_applications.c
    src/cmd_agents.c
    src/cmd_dynamic.c
    src/cmd_tcbstats.c
    src/cmd_tables.c
    src/cmd_indexes.c
    src/cmd_mempools.c
    src/cmd_transactions.c
    src/cmd_utilities.c
    src/cmd_reorgs.c
    src/cmd_hadr.c
    src/cmd_stat.c
    src/cmd_kill.c
    src/cmd_osinfo.c
    src/cmd_diag.c
    src/cmd_sharding.c
)

add_executable(mongopd ${SOURCES})

target_include_directories(mongopd PRIVATE
    ${MONGOC_INCLUDE_DIRS}
    ${BSON_INCLUDE_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(mongopd PRIVATE
    ${MONGOC_LIBRARIES}
    ${BSON_LIBRARIES}
)

target_compile_definitions(mongopd PRIVATE
    ${MONGOC_DEFINITIONS}
    ${BSON_DEFINITIONS}
)

target_compile_options(mongopd PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS mongopd DESTINATION bin)

# ── Convenience targets ──────────────────────────────────────────────────────
add_custom_target(install-user
    COMMAND ${CMAKE_COMMAND} --install . --prefix $ENV{HOME}
    DEPENDS mongopd
    COMMENT "Installing mongopd to ~/bin"
)
