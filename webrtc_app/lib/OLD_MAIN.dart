import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';
import 'package:webrtc_app/VideoCalling.dart';
import 'package:webrtc_app/VoiceCalling.dart'; // Importar pantalla de llamada de voz

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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
  bool _inCall = false;

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
    _localStream?.dispose();
    _peerConnection?.close();
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
      _showCallDialog(description, data['isVideoCall']);
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

  void _getMediaDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      setState(() {
        _cameras =
            devices.where((device) => device.kind == 'videoinput').toList();
        _microphones =
            devices.where((device) => device.kind == 'audioinput').toList();
        if (_cameras.isNotEmpty) {
          _selectedCamera = _cameras.firstWhere(
            (camera) => camera.label.toLowerCase().contains('front'),
            orElse: () => _cameras[0],
          );
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
    try {
      var offer =
          await _peerConnection?.createOffer({'offerToReceiveVideo': true});
      await _peerConnection?.setLocalDescription(offer!);
      _socket?.emit('offer',
          {'sdp': offer?.sdp, 'type': offer?.type, 'isVideoCall': true});
      setState(() {
        _inCall = true;
      });

      String callerName = "Javier Gutierrez Ramirez";

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ScreenCalling(
            localRenderer: _localRenderer,
            remoteRenderer: _remoteRenderer,
            onHangUp: _hangUp,
            callerName: callerName,
            callerNumber: "4772284248",
          ),
        ),
      );
    } catch (e) {
      print('Error starting video call: $e');
    }
  }

  void _startVoiceCall() async {
    try {
      var offer =
          await _peerConnection?.createOffer({'offerToReceiveVideo': false});
      await _peerConnection?.setLocalDescription(offer!);
      _socket?.emit('offer',
          {'sdp': offer?.sdp, 'type': offer?.type, 'isVideoCall': false});
      setState(() {
        _inCall = true;
      });

      String callerName = "Javier Gutierrez Ramirez";

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ScreenVoiceCalling(
            localRenderer: _localRenderer,
            remoteRenderer: _remoteRenderer,
            onHangUp: _hangUp,
            callerName: callerName,
            callerNumber: "4772284248",
            incomingStream:
                null, // No se necesita stream de video en llamadas de voz
          ),
        ),
      );
    } catch (e) {
      print('Error starting voice call: $e');
    }
  }

  void _hangUp() {
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });

    _localStream?.dispose();
    _peerConnection?.close();
    _createPeerConnection();

    Navigator.pop(context);

    setState(() {
      _inCall = false;
    });
  }

  void _showCallDialog(RTCSessionDescription description, bool isVideoCall) async {
    final _audioPlayer = AudioPlayer();
    bool _isRinging = true;

    void playRingtoneAndVibration() {
      _audioPlayer.setAsset('lib/assets/ringtone.mp3').then((_) {
        _audioPlayer.play().catchError((error) {
          print('Error reproduciendo tono de llamada: $error');
        });
      }).catchError((error) {
        print('Error cargando tono de llamada: $error');
      });

      Vibration.hasVibrator().then((hasVibrator) {
        if (hasVibrator == true) {
          Vibration.vibrate(pattern: [500, 1000, 500, 2000]);
        }
      }).catchError((error) {
        print('Error al verificar la vibración: $error');
      });
    }

    showDialog(
      context: MyApp.navigatorKey.currentState!.overlay!.context,
      builder: (BuildContext context) {
        playRingtoneAndVibration();

        return WillPopScope(
          onWillPop: () async {
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
                  _audioPlayer.stop();
                  Vibration.cancel();
                  _peerConnection?.close();
                  _createPeerConnection();
                  setState(() {
                    _inCall = false;
                  });
                },
              ),
              TextButton(
                child: Text('Aceptar'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  _audioPlayer.stop();
                  Vibration.cancel();
                  await _peerConnection?.setRemoteDescription(description);
                  var answer = await _peerConnection?.createAnswer();
                  await _peerConnection?.setLocalDescription(answer!);
                  _socket?.emit('answer', {
                    'sdp': answer?.sdp,
                    'type': answer?.type,
                  });

                  if (isVideoCall) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ScreenCalling(
                          localRenderer: _localRenderer,
                          remoteRenderer: _remoteRenderer,
                          onHangUp: _hangUp,
                          callerName: "Nombre de llamante",
                          callerNumber: "Número de llamante",
                        ),
                      ),
                    );
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ScreenVoiceCalling(
                          localRenderer: _localRenderer,
                          remoteRenderer: _remoteRenderer,
                          onHangUp: _hangUp,
                          callerName: "Nombre de llamante",
                          callerNumber: "Número de llamante",
                          incomingStream:
                              null, // No se necesita stream de video en llamadas de voz
                        ),
                      ),
                    );
                  }

                  setState(() {
                    _inCall = true;
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
                icon: Icon(Icons.video_call),
                onPressed: _inCall ? null : _startCall,
              ),
              IconButton(
                icon: Icon(Icons.call),
                onPressed: _inCall
                    ? null
                    : _startVoiceCall, // Nuevo botón para llamada de voz
              ),
            ],
          ),
        ],
      ),
    );
  }
}



