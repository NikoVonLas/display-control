#ifndef ACER_DISPLAY_CONTROL_DDC_BRIDGE_H
#define ACER_DISPLAY_CONTROL_DDC_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include "NightShift.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ADC_DISPLAY_UUID_LENGTH 64
#define ADC_DISPLAY_NAME_LENGTH 128
#define ADC_MANUFACTURER_LENGTH 16

enum {
    ADC_SUCCESS = 0,
    ADC_ERROR_INVALID_ARGUMENT = -1,
    ADC_ERROR_DISPLAY_NOT_FOUND = -2,
    ADC_ERROR_TRANSPORT_NOT_FOUND = -3,
    ADC_ERROR_COMMUNICATION = -4,
    ADC_ERROR_MALFORMED_REPLY = -5,
    ADC_ERROR_UNSUPPORTED_FEATURE = -6,
    ADC_ERROR_DISPLAY_CONFIGURATION = -7,
    ADC_ERROR_DISPLAY_API_UNAVAILABLE = -8,
    ADC_ERROR_LAST_ACTIVE_DISPLAY = -9
};

typedef struct {
    uint32_t displayID;
    uint32_t vendorID;
    uint32_t modelID;
    uint32_t serialNumber;
    char uuid[ADC_DISPLAY_UUID_LENGTH];
    char productName[ADC_DISPLAY_NAME_LENGTH];
    char manufacturer[ADC_MANUFACTURER_LENGTH];
} ADCDisplayInfo;

typedef struct {
    uint8_t resultCode;
    uint8_t featureCode;
    uint8_t typeCode;
    uint16_t maximumValue;
    uint16_t currentValue;
} ADCVCPReply;

int32_t ADCListDisplays(ADCDisplayInfo *displays, int32_t capacity);
int32_t ADCReadVCP(const char *displayUUID, uint8_t featureCode, ADCVCPReply *reply);
int32_t ADCWriteVCP(const char *displayUUID, uint8_t featureCode, uint16_t value);
int32_t ADCSetDisplayEnabled(uint32_t displayID, bool enabled);
bool ADCDisplayIsActive(uint32_t displayID);
const char *ADCErrorDescription(int32_t errorCode);

#ifdef __cplusplus
}
#endif

#endif
