#include "power.h"
#include "i2c_bsp.h"
#include "XPowersLib.h"
#include "esp_log.h"
static XPowersPMU pmu;
static int read_pmu(uint8_t addr,uint8_t reg,uint8_t *data,uint8_t len) {
    return i2c_read_reg(addr,reg,data,len)==ESP_OK ? 0 : -1;
}
static int write_pmu(uint8_t addr,uint8_t reg,uint8_t *data,uint8_t len) {
    return i2c_write_reg(addr,reg,data,len)==ESP_OK ? 0 : -1;
}
extern "C" esp_err_t inknote_screen_power_init(void) {
    if (!pmu.begin(AXP2101_SLAVE_ADDRESS,read_pmu,write_pmu)) return ESP_FAIL;
    // Match the official screen supply only; leave charge settings unchanged.
    if (!pmu.setALDO3Voltage(3300) || !pmu.enableALDO3()) return ESP_FAIL;
    if (!pmu.isEnableALDO3() || pmu.getALDO3Voltage()!=3300) return ESP_FAIL;
    ESP_LOGI("InkNotePower","ALDO3 enabled at 3300 mV; battery=%d%%",pmu.getBatteryPercent());
    return ESP_OK;
}
