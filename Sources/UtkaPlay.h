#pragma once

#include <stdint.h>

/// 1, если виртуальный выход уже есть в системе.
int UtkaPlayOpen(void);
/// Отдаёт кольцо в это устройство. 0 — получилось.
int UtkaPlayStart(uint32_t deviceID);
/// Останавливает отдачу, кольцо не закрывает.
void UtkaPlayStop(void);
void UtkaPlayClose(void);
/// Куда сейчас пишем. 0 — никуда.
uint32_t UtkaPlayDevice(void);
