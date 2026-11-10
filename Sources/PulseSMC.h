#pragma once

/// Читает температуру чипа через SMC. 1 — есть градусы в celsius, 0 — не вышло.
int PulseSMCReadCelsius(double *celsius);
