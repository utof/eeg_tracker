import 'package:flutter/services.dart';
import 'package:neurosdk2/constants.dart';


class SensorEventChannels {
  static final Stream<dynamic> connectionChangedStream = const EventChannel(Constants.connectionChangedEventName).receiveBroadcastStream();
  static final Stream<dynamic> batteryChangedStream = const EventChannel(Constants.batteryChangedEventName).receiveBroadcastStream();
  static final Stream<dynamic> signalChangedStream = const EventChannel(Constants.signalEventName).receiveBroadcastStream();
  static final Stream<dynamic> sensorListChangedStream = const EventChannel(Constants.sensorListChangedEventName).receiveBroadcastStream();
  
  static final Stream<dynamic> memsDataChangedStream = const EventChannel(Constants.memsDataChangedEventName).receiveBroadcastStream();
  
  
  static final Stream<dynamic> neurosmartFPGDataChangedStream = const EventChannel(Constants.neurosmartFPGDataChangedEventName).receiveBroadcastStream();
  static final Stream<dynamic> resistanceChangedStream = const EventChannel(Constants.resistanceEventName).receiveBroadcastStream();
  
  
  static final Stream<dynamic> ampModeChangedStream = const EventChannel(Constants.ampModeChangedEventName).receiveBroadcastStream();
  
  
  static final Stream<dynamic> callibriElectrodeChangedStream = const EventChannel(Constants.callibriElectrodeStateEventName).receiveBroadcastStream();
  static final Stream<dynamic> callibriEnvelopeDataChangedStream = const EventChannel(Constants.callibriEnvelopeDataEventName).receiveBroadcastStream();
  static final Stream<dynamic> callibriRespirationDataChangedStream = const EventChannel(Constants.callibriRespirationDataEventName).receiveBroadcastStream();
  static final Stream<dynamic> quaternionDataChangedStream = const EventChannel(Constants.quaternionDataChangedEventName).receiveBroadcastStream();
  
}