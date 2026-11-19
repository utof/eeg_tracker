import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:neurosdk2/cmn_types.dart';
import 'package:neurosdk2/event_channel_stream_wrapper.dart';
import 'package:neurosdk2/sensors_field.dart';
import 'package:neurosdk2/pigeon_messages.g.dart';
import 'package:neurosdk2/sensor_event_channels.dart';

mixin MEMSSensor {

  late final SensorGetProperty<FSensorSamplingFrequency> samplingFrequencyMEMS =
      SensorGetProperty(_guid, _api.getSamplingFrequency);
  late final SensorGetSetProperty<FSensorAccelerometerSensitivity> accSens =
      SensorGetSetProperty(_guid, _api.getAccSens, _api.setAccSens);
  late final SensorGetSetProperty<FSensorGyroscopeSensitivity> gyroSens =
      SensorGetSetProperty(_guid, _api.getGyroSens, _api.setGyroSens);

  Stream<List<MEMSData>> get memsDataStream => _memsChanelStreamWrapper.stream;

  late final String _guid;
  late final NeuroApi _api;
  late final EventChannelStreamWrapper<List<MEMSData>> _memsChanelStreamWrapper;

  @protected
  @mustCallSuper
  initMEMS(String guid, NeuroApi api) {
    _guid = guid;
    _api = api;
    _memsChanelStreamWrapper = EventChannelStreamWrapper(
        _guid, SensorEventChannels.memsDataChangedStream, _onMEMSDataReceived);
  }

  @protected
  @mustCallSuper
  void disposeMEMS() {
    _memsChanelStreamWrapper.dispose();
  }

  List<MEMSData> _onMEMSDataReceived(dynamic data) {
    List<MEMSData> samples = List.unmodifiable(
      data.map<MEMSData>((element) {
        var accelerometer = Point3D(
          x: element['Accelerometer']['X'],
          y: element['Accelerometer']['Y'],
          z: element['Accelerometer']['Z'],
        );

        var gyroscope = Point3D(
          x: element['Gyroscope']['X'],
          y: element['Gyroscope']['Y'],
          z: element['Gyroscope']['Z'],
        );

        return MEMSData(
          packNum: element['PackNum'],
          accelerometer: accelerometer,
          gyroscope: gyroscope,
        );
      }),
    );
    return samples;
  }
}
