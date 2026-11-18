from enum import Enum


class SensorFamily(Enum):
    LEBrainBit = 3
    LEBrainBitBlack = 18


class SensorState(Enum):
    StateInRange = 0
    StateOutOfRange = 1


class SensorCommand(Enum):
    StartSignal = 0
    StopSignal = 1
    StartResist = 2
    StopResist = 3
