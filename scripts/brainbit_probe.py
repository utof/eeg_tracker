"""Scan for BrainBit devices, connect, print features and 5 s of signal + resistance."""
import time
from neurosdk.scanner import Scanner
from neurosdk.cmn_types import SensorFamily, SensorFeature, SensorCommand, SensorState

sc = Scanner([SensorFamily.LEBrainBit, SensorFamily.LEBrainBitBlack, SensorFamily.LEBrainBit2,
              SensorFamily.LEBrainBitPro, SensorFamily.LEBrainBitFlex])
sc.start(); time.sleep(8); sc.stop()
found = sc.sensors()
print("found:", found)
if not found:
    raise SystemExit(1)
s = sc.create_sensor(found[0])
print("name", s.name, "family", s.sens_family, "state", s.state)
for attr in ("features", "commands", "parameters"):
    try:
        print(attr, getattr(s, attr))
    except Exception as e:
        print(attr, "ERR", e)
for attr in ("batt_power", "sampling_frequency", "gain", "firmware_mode", "version", "serial_number"):
    try:
        print(attr, getattr(s, attr))
    except Exception as e:
        print(attr, "ERR", e)
sig = []
res = []
s.signalDataReceived = lambda sensor, data: sig.extend(data)
s.resistDataReceived = lambda sensor, data: res.append(data)
if s.is_supported_command(SensorCommand.StartResist):
    s.exec_command(SensorCommand.StartResist); time.sleep(3); s.exec_command(SensorCommand.StopResist)
print("resist packets", len(res), res[-1:] )
s.exec_command(SensorCommand.StartSignal); time.sleep(5); s.exec_command(SensorCommand.StopSignal)
print("signal samples", len(sig), sig[:2])
s.disconnect(); del s; del sc
