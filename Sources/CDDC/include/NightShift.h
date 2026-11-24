#pragma once

#include <stdbool.h>

bool ADCNightShiftRead(bool *enabled, float *strength);
bool ADCNightShiftSetEnabled(bool enabled);
bool ADCNightShiftSetStrength(float strength);
