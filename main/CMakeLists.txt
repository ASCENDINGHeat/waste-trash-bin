idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES
        esp_driver_gpio
        esp_driver_ledc
        esp_driver_i2c
        esp_driver_rmt
        esp_timer
        esp_pm
        esp_hw_support
        esp_psram
        esp_wifi
        esp_event
        esp_netif
        bt
        mqtt
        nvs_flash
)
