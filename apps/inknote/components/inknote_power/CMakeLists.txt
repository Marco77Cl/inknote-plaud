set(POWER_SRC "${CMAKE_CURRENT_LIST_DIR}/../../../../vendor/waveshare/ESP-IDF/08_ESP32-S3_e-Paper-3.97/components/axpPower/src")
idf_component_register(SRCS "power.cpp" "${POWER_SRC}/XPowersLibInterface.cpp" INCLUDE_DIRS "." "${POWER_SRC}" REQUIRES i2c_bsp driver)
target_compile_definitions(${COMPONENT_LIB} PRIVATE XPOWERS_CHIP_AXP2101 CONFIG_XPOWERS_ESP_IDF_NEW_API)
