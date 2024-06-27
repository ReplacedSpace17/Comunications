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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // Asignar la GlobalKey al MaterialApp
      title: 'WebRTC Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
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
      if (event.track.kind == 'video') {
        _remoteRenderer.srcObject = event.streams[0];
      }
    };

    _localStream = await _getUserMedia();
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });
  }

  Future<MediaStream> _getUserMedia() async {
    try {
      final Map<String, dynamic> mediaConstraints = {
        'audio': _selectedMicrophone != null
            ? {'deviceId': _selectedMicrophone!.deviceId}
            : true,
        'video': _selectedCamera != null
            ? {'deviceId': _selectedCamera!.deviceId}
            : true,
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

  void _startVideoCall() async {
    try {
      var offer = await _peerConnection?.createOffer({});
      await _peerConnection?.setLocalDescription(offer!);
      _socket?.emit('offer', {'sdp': offer?.sdp, 'type': offer?.type});
      setState(() {
        _inCall = true; // Indicar que estamos en llamada activa
      });
    } catch (e) {
      print('Error starting video call: $e');
    }
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
                    _inCall = false;
                  });
                },
              ),
              TextButton(
                child: Text('Aceptar'),
                onPressed: () {
                  Navigator.of(context).pop();
                  _audioPlayer.stop(); // Detener tono de llamada
                  Vibration.cancel(); // Detener vibración
                  _peerConnection?.setRemoteDescription(description);
                  _peerConnection?.createAnswer().then((answer) {
                    _peerConnection?.setLocalDescription(answer);
                    _socket?.emit('answer', {
                      'sdp': answer.sdp,
                      'type': answer.type,
                    });
                    setState(() {
                      _inCall = true; // Indicar que estamos en llamada activa
                    });
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _switchCamera() async {
    if (_localStream != null) {
      final videoTrack = _localStream!
          .getVideoTracks()
          .firstWhere((track) => track.kind == 'video');
      await Helper.switchCamera(videoTrack);
    }
  }

  void _muteMic() async {
    if (_localStream != null) {
      final audioTrack = _localStream!
          .getAudioTracks()
          .firstWhere((track) => track.kind == 'audio');
      final enabled = audioTrack.enabled;
      audioTrack.enabled = !enabled;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebRTC Demo'),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: RTCVideoView(_localRenderer, mirror: true),
          ),
          Expanded(
            child: RTCVideoView(_remoteRenderer),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton(
                icon: Icon(Icons.call),
                onPressed: _inCall ? null : _startCall,
              ),
              IconButton(
                icon: Icon(Icons.switch_camera),
                onPressed: _switchCamera,
              ),
              IconButton(
                icon: Icon(Icons.mic_off),
                onPressed: _muteMic,
              ),
              IconButton(
                icon: Icon(Icons.call_end),
                onPressed: _inCall ? _hangUp : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
