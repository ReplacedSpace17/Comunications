import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
    // _socket?.disconnect(); // No desconectar el socket al cerrar la página

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
      var answer = await _peerConnection?.createAnswer({});
      await _peerConnection?.setLocalDescription(answer!);
      _socket?.emit('answer', {'sdp': answer?.sdp, 'type': answer?.type});
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
        _cameras = devices
            .where((device) => device.kind == 'videoinput')
            .toList();
        _microphones = devices
            .where((device) => device.kind == 'audioinput')
            .toList();
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
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    _localStream?.dispose();
    _peerConnection?.close(); // Cerrar la conexión WebRTC
    // No desconectar el socket al colgar
    // _socket?.disconnect(); 

    setState(() {
      _inCall = false; // Indicar que no estamos en llamada activa
    });
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
              onPressed: _hangUp,
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
