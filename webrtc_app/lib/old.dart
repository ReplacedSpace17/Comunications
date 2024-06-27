
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';

import 'calling_screen.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // GlobalKey para acceder al contexto del MaterialApp
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey();

  // Callback function for hang-up action
  static void Function() hangUpCallback = () {
    
  };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // Asignar la GlobalKey al MaterialApp
      title: 'WebRTC Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(
        hangUp: hangUpCallback, // Pass the hang-up callback to MyHomePage
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final void Function() hangUp; // Callback to trigger hang-up action

  MyHomePage({required this.hangUp});

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  IO.Socket? _socket;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  List<MediaDeviceInfo> _cameras = [];
  List<MediaDeviceInfo> _microphones = [];
  MediaDeviceInfo? _selectedCamera;
  MediaDeviceInfo? _selectedMicrophone;
  bool _inCall = false; // Estado de la llamada actual

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeRenderers();
    _connectSocket();
    _createPeerConnection();
    _getMediaDevices();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.dispose(); // Liberar MediaStream local
    _peerConnection?.close(); // Cerrar la conexión WebRTC
    super.dispose();
  }

  Future<void> _initializeRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  void _requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
    ].request();
  }

  void _connectSocket() {
    _socket = IO.io('http://192.168.1.76:3000', <String, dynamic>{
      'transports': ['websocket'],
    });

    _socket?.on('connect', (_) {
      print('connected');
    });

    _socket?.on('offer', (data) async {
      var description = RTCSessionDescription(data['sdp'], data['type']);
      await _peerConnection?.setRemoteDescription(description);

      // Mostrar alerta para aceptar o rechazar la llamada
      _showCallDialog(description);
    });

    _socket?.on('answer', (data) async {
      var description = RTCSessionDescription(data['sdp'], data['type']);
      await _peerConnection?.setRemoteDescription(description);
    });

    _socket?.on('candidate', (data) async {
      var candidate = RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      );
      await _peerConnection?.addCandidate(candidate);
    });
  }

  Future<void> _createPeerConnection() async {
    // Limpiar la conexión previa si existe
    await _peerConnection?.close();

    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    }, {});

    _peerConnection?.onIceCandidate = (candidate) {
      _socket?.emit('candidate', {
        'candidate': candidate?.candidate,
        'sdpMid': candidate?.sdpMid,
        'sdpMLineIndex': candidate?.sdpMLineIndex,
      });
    };

    _peerConnection?.onTrack = (event) {
      if (event.track.kind == 'audio') {
        // Solo manejar pistas de audio
        _remoteStream = event.streams[0];
      }
    };

    _localStream = await _getUserMedia();
    _localStream!.getTracks().forEach((track) {
      // Solo agregar pistas de audio
      if (track.kind == 'audio') {
        _peerConnection!.addTrack(track, _localStream!);
      }
    });
  }

  Future<MediaStream> _getUserMedia() async {
    try {
      final Map<String, dynamic> mediaConstraints = {
        'audio': _selectedMicrophone != null
            ? {'deviceId': _selectedMicrophone!.deviceId}
            : true,
        'video': false, // Configurar para no obtener video
      };
      return await navigator.mediaDevices.getUserMedia(mediaConstraints);
    } catch (e) {
      print('Error getting user media: $e');
      throw e;
    }
  }

  Future<void> _getMediaDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      setState(() {
        _cameras =
            devices.where((device) => device.kind == 'videoinput').toList();
        _microphones =
            devices.where((device) => device.kind == 'audioinput').toList();
        if (_cameras.isNotEmpty) {
          _selectedCamera = _cameras[0];
        }
        if (_microphones.isNotEmpty) {
          _selectedMicrophone = _microphones[0];
        }
      });
    } catch (e) {
      print('Error enumerating devices: $e');
    }
  }

  void _startCall() async {
    var offer = await _peerConnection?.createOffer({});
    await _peerConnection?.setLocalDescription(offer!);
    _socket?.emit('offer', {'sdp': offer?.sdp, 'type': offer?.type});
    setState(() {
      _inCall = true; // Indicar que estamos en llamada activa
    });
  }


void _hangUp() {
  // Detener todos los tracks del MediaStream local
  _localStream?.getTracks().forEach((track) {
    track.stop();
  });

  // Liberar el MediaStream local y cerrar la conexión PeerConnection
  _localStream?.dispose();
  _peerConnection?.close();

  // Reiniciar la conexión PeerConnection para una nueva llamada
  _createPeerConnection();

  // Actualizar el estado para indicar que no estamos en una llamada activa
  setState(() {
    _inCall = false;
  });
}


  void _showCallDialog(RTCSessionDescription description) async {
    final _audioPlayer = AudioPlayer();
    bool _isRinging = true;

    // Función para reproducir el tono de llamada y vibración en bucle
    void playRingtoneAndVibration() {
      // Reproducir tono de llamada de forma asíncrona
      _audioPlayer.setAsset('lib/assets/ringtone.mp3').then((_) {
        _audioPlayer.play().catchError((error) {
          print('Error reproduciendo tono de llamada: $error');
        });
      }).catchError((error) {
        print('Error cargando tono de llamada: $error');
      });

      // Hacer vibrar el dispositivo de forma asíncrona
      Vibration.hasVibrator().then((hasVibrator) {
        if (hasVibrator == true) {
          Vibration.vibrate(pattern: [500, 1000, 500, 2000]);
        }
      }).catchError((error) {
        print('Error al verificar la vibración: $error');
      });
    }

    // Mostrar la alerta cuando estén listos tanto el tono como la vibración
    showDialog(
      context: MyApp.navigatorKey.currentState!.overlay!.context,
      builder: (BuildContext context) {
        // Llamar a la función para iniciar el tono de llamada y la vibración
        playRingtoneAndVibration();

        return WillPopScope(
          onWillPop: () async {
            // Impedir que se cierre la alerta presionando el botón de retroceso
            return false;
          },
          child: AlertDialog(
            title: Text('Llamada entrante'),
            content: Text('¿Deseas aceptar la llamada?'),
            actions: <Widget>[
              TextButton(
                child: Text('Rechazar'),
                onPressed: () {
                  Navigator.of(context).pop();
                  _audioPlayer.stop(); // Detener tono de llamada
                  Vibration.cancel(); // Detener vibración
                  _peerConnection?.close();
                  _createPeerConnection(); // Reiniciar la conexión
                  setState(() {
                    _inCall = false; // Indicar que no estamos en llamada activa
                    _isRinging = false; // Detener el bucle de tono y vibración
                  });
                },
              ),
              TextButton(
                child: Text('Aceptar'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  _audioPlayer.stop(); // Detener tono de llamada
                  Vibration.cancel(); // Detener vibración
                  var answer = await _peerConnection?.createAnswer({});
                  await _peerConnection?.setLocalDescription(answer!);
                  _socket?.emit(
                      'answer', {'sdp': answer?.sdp, 'type': answer?.type});
                  setState(() {
                    _inCall = true; // Indicar que estamos en llamada activa
                    _isRinging = false; // Detener el bucle de tono y vibración
                  });

                  // Navegar a la pantalla de llamada en curso
                  Navigator.push(
                    MyApp.navigatorKey.currentState!.overlay!.context,
                    MaterialPageRoute(builder: (context) => CallingScreen()),
                  );
                },
              ),
            ],
          ),
        );
      },
    );

    // Repetir tono de llamada y vibración mientras la alerta esté visible
    while (_isRinging) {
      await Future.delayed(Duration(seconds: 4));
      if (_isRinging) {
        playRingtoneAndVibration();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebRTC Demo'),
      ),
      body: Column(
        children: [
          Expanded(child: RTCVideoView(_localRenderer, mirror: true)),
          Expanded(child: RTCVideoView(_remoteRenderer)),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cameras:'),
                DropdownButton<MediaDeviceInfo>(
                  value: _selectedCamera,
                  items: _cameras.map((camera) {
                    return DropdownMenuItem<MediaDeviceInfo>(
                      value: camera,
                      child: Text(camera.label),
                    );
                  }).toList(),
                  onChanged: (camera) {
                    setState(() {
                      _selectedCamera = camera;
                      _localStream?.dispose();
                      _getUserMedia().then((stream) {
                        _localStream = stream;
                        _peerConnection?.removeStream(_localStream!);
                        _peerConnection?.addStream(_localStream!);
                      });
                    });
                  },
                ),
                SizedBox(height: 8),
                Text('Microphones:'),
                DropdownButton<MediaDeviceInfo>(
                  value: _selectedMicrophone,
                  items: _microphones.map((mic) {
                    return DropdownMenuItem<MediaDeviceInfo>(
                      value: mic,
                      child: Text(mic.label),
                    );
                  }).toList(),
                  onChanged: (mic) {
                    setState(() {
                      _selectedMicrophone = mic;
                      _localStream?.dispose();
                      _getUserMedia().then((stream) {
                        _localStream = stream;
                        _peerConnection?.removeStream(_localStream!);
                        _peerConnection?.addStream(_localStream!);
                      });
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _inCall
          ? FloatingActionButton(
              onPressed: widget.hangUp, // Use the callback provided by MyApp
              tooltip: 'Hang Up',
              child: Icon(Icons.call_end),
              backgroundColor: Colors.red,
            )
          : FloatingActionButton(
              onPressed: _startCall,
              tooltip: 'Start Call',
              child: Icon(Icons.phone),
            ),
    );
  }
}
