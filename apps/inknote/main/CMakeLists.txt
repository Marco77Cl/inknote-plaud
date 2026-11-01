idf_component_register(SRCS "main.c" "ui_render.c" INCLUDE_DIRS "." REQUIRES driver fatfs sdmmc esp_timer epaper_port epaper_lib es8311_bsp i2c_bsp inknote_power)
