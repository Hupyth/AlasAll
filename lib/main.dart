import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  runApp(const MyApp());
}

class EventItem {
  int hour;
  int minute;
  String title;
  List<String?> mp3ByWeekday;
  List<bool> weekdays;
  bool enabled;
  bool completed;
  
  EventItem({
    required this.hour,
    required this.minute,
    required this.title,
    List<String?>? mp3ByWeekday,
    List<bool>? weekdays,
    this.enabled = true,
    this.completed = false,
  })  : mp3ByWeekday = mp3ByWeekday ?? List<String?>.filled(7, null),
        weekdays = weekdays ?? List<bool>.filled(7, true);

  Map<String, dynamic> toJson() => {
        'hour': hour,
        'minute': minute,
        'title': title,
        'mp3ByWeekday': mp3ByWeekday,
        'weekdays': weekdays,
        'enabled': enabled,
        'completed': completed,
      };

  static EventItem fromJson(Map<String, dynamic> j) => EventItem(
        hour: j['hour'],
        minute: j['minute'],
        title: j['title'],
        mp3ByWeekday: List<String?>.from(j['mp3ByWeekday'] ?? List.filled(7, null)),
        weekdays: List<bool>.from(j['weekdays'] ?? List.filled(7, true)),
        enabled: j['enabled'] ?? true,
        completed: j['completed'] ?? false,
      );

  bool get isOverdue {
    final now = DateTime.now();
    final eventTime = DateTime(now.year, now.month, now.day, hour, minute);
    return now.isAfter(eventTime);
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final List<EventItem> events = [];
  late SharedPreferences prefs;
  final FlutterLocalNotificationsPlugin fln = FlutterLocalNotificationsPlugin();
  final AudioPlayer audioPlayer = AudioPlayer();
  final FlutterTts tts = FlutterTts();
  bool silentLoopOn = false;
  double musicVolume = 0.8;
  double voiceVolume = 1.0;
  final List<AudioPlayer> activePlayers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initEverything();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    audioPlayer.dispose();
    for (var player in activePlayers) {
      player.dispose();
    }
    tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkCompletedEvents();
    }
  }

  Future<void> initEverything() async {
    prefs = await SharedPreferences.getInstance();
    await _initNotifications();
    _loadSavedEvents();
    _startSilentLoopIfNeeded();
    _checkCompletedEvents();
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    
    await fln.initialize(initSettings, onDidReceiveNotificationResponse: (response) async {
      final payload = response.payload;
      if (payload != null) {
        final data = jsonDecode(payload);
        final eventIndex = data['eventIndex'];
        final weekday = data['weekday'];
        await playAlarm(eventIndex, weekday);
      }
    });
  }

  void _loadSavedEvents() {
    final raw = prefs.getString('events_json');
    if (raw != null) {
      final List decoded = jsonDecode(raw);
      for (var e in decoded) {
        events.add(EventItem.fromJson(Map<String, dynamic>.from(e)));
      }
      setState(() {});
      _scheduleAllEvents();
    }
  }

  Future<void> _saveEvents() async {
    final enc = jsonEncode(events.map((e) => e.toJson()).toList());
    await prefs.setString('events_json', enc);
  }

  void _checkCompletedEvents() {
    final now = DateTime.now();
    setState(() {
      for (var event in events) {
        final eventTime = DateTime(now.year, now.month, now.day, event.hour, event.minute);
        if (now.isAfter(eventTime) && !event.completed) {
          event.completed = true;
        }
      }
    });
    _saveEvents();
  }

  Future<void> toggleComplete(int index) async {
    setState(() {
      events[index].completed = !events[index].completed;
    });
    await _saveEvents();
  }

  Future<void> importTxt() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (res == null) return;
      
      final path = res.files.single.path!;
      final file = File(path);
      final content = await file.readAsString();
      final lines = content.split(RegExp(r'\r?\n'));
      final regex = RegExp(r'^(\d{1,2})\.(\d{1,2})\s*:\s*(.+)$');
      
      for (var l in lines) {
        final m = regex.firstMatch(l);
        if (m != null) {
          final h = int.parse(m.group(1)!);
          final mm = int.parse(m.group(2)!);
          final title = m.group(3)!.trim();
          
          // Check if event already exists
          final exists = events.any((e) => e.hour == h && e.minute == mm && e.title == title);
          if (!exists) {
            events.add(EventItem(hour: h, minute: mm, title: title));
          }
        }
      }
      
      await _saveEvents();
      setState(() {});
      _scheduleAllEvents();
      
      // Show success message
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã import ${lines.length} sự kiện')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi import: $e')),
        );
      }
    }
  }

  int _notifId(int eventIndex, int weekdayIndex) => eventIndex * 10 + weekdayIndex + 1000;

  Future<void> _scheduleAllEvents() async {
    await fln.cancelAll();
    
    for (int i = 0; i < events.length; i++) {
      final ev = events[i];
      if (!ev.enabled) continue;

      for (int d = 0; d < 7; d++) {
        if (!ev.weekdays[d]) continue;
        
        final now = tz.TZDateTime.now(tz.local);
        final targetWeekday = d + 1;
        
        tz.TZDateTime scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, ev.hour, ev.minute);
        while (scheduled.weekday != targetWeekday) {
          scheduled = scheduled.add(const Duration(days: 1));
        }
        if (scheduled.isBefore(now)) {
          scheduled = scheduled.add(const Duration(days: 7));
        }

        final payload = jsonEncode({'eventIndex': i, 'weekday': d});
        
        await fln.zonedSchedule(
          _notifId(i, d),
          'AlasAll - ${ev.title}',
          '${ev.hour.toString().padLeft(2, '0')}:${ev.minute.toString().padLeft(2, '0')}',
          scheduled,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'alarm_channel',
              'Alarm Notifications',
              channelDescription: 'Thông báo báo thức',
              importance: Importance.max,
              priority: Priority.high,
              playSound: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          payload: payload,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          androidAllowWhileIdle: true,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
      }
    }
  }

  Future<void> _startSilentLoopIfNeeded() async {
    if (!silentLoopOn && events.any((e) => e.enabled)) {
      try {
        // Tạo file silent ảo
        final dir = await getTemporaryDirectory();
        final silentFile = File('${dir.path}/silent.mp3');
        if (!await silentFile.exists()) {
          await silentFile.writeAsBytes(List.filled(100, 0)); // File rỗng
        }
        
        await audioPlayer.setFilePath(silentFile.path);
        await audioPlayer.setVolume(0.0);
        await audioPlayer.setLoopMode(LoopMode.one);
        await audioPlayer.play();
        silentLoopOn = true;
      } catch (e) {
        print('Silent loop error: $e');
      }
    }
  }

  Future<AudioPlayer> _playMp3WithLoopLogic(String mp3Path, double volume) async {
    final player = AudioPlayer();
    activePlayers.add(player);
    
    try {
      await player.setFilePath(mp3Path);
      Duration? dur = player.duration;
      if (dur == null) {
        await Future.delayed(const Duration(milliseconds: 500));
        dur = player.duration ?? Duration.zero;
      }

      if (dur.inSeconds <= 20) {
        await player.setLoopMode(LoopMode.one);
      } else {
        await player.setLoopMode(LoopMode.off);
      }
      
      await player.setVolume(volume);
      await player.play();

      // Auto-stop sau 2 phút
      Timer(const Duration(minutes: 2), () async {
        try {
          if (player.playing) await player.stop();
          activePlayers.remove(player);
          await player.dispose();
        } catch (_) {}
      });
      
    } catch (e) {
      activePlayers.remove(player);
      await player.dispose();
    }
    
    return player;
  }

  Future<void> playAlarm(int eventIndex, int weekdayIndex) async {
    final ev = events[eventIndex];
    String? mp3 = ev.mp3ByWeekday[weekdayIndex];
    mp3 ??= ev.mp3ByWeekday.firstWhere((e) => e != null, orElse: () => null);

    await _startSilentLoopIfNeeded();

    AudioPlayer? musicPlayer;
    if (mp3 != null && File(mp3).existsSync()) {
      musicPlayer = await _playMp3WithLoopLogic(mp3, musicVolume);
    }

    // Sequence giọng nói
    final String txt = '${ev.hour} giờ ${ev.minute} phút: ${ev.title}';
    
    // Giọng nam
    await tts.setVolume(voiceVolume);
    await tts.setSpeechRate(0.5);
    await tts.speak(txt);

    // Giọng nữ sau 2s
    Timer(const Duration(seconds: 2), () async {
      await tts.setVolume(voiceVolume);
      await tts.setSpeechRate(0.5);
      await tts.speak(txt);
    });

    // Giọng robot sau 4s
    Timer(const Duration(seconds: 4), () async {
      await tts.setVolume(voiceVolume);
      await tts.setPitch(0.3);
      await tts.setSpeechRate(0.8);
      await tts.speak(txt);
      
      Timer(const Duration(seconds: 3), () {
        tts.setPitch(1.0);
        tts.setSpeechRate(0.5);
      });
    });

    // Mark as completed
    if (!ev.completed) {
      toggleComplete(eventIndex);
    }
  }

  Future<void> testAlarmMix(String? mp3Path, {double musicVol = 0.8, double voiceVol = 1.0}) async {
    await _startSilentLoopIfNeeded();
    
    AudioPlayer? testPlayer;
    if (mp3Path != null && File(mp3Path).existsSync()) {
      testPlayer = await _playMp3WithLoopLogic(mp3Path, musicVol);
    }

    await tts.setVolume(voiceVol);
    await tts.speak('Đây là giọng nam thử nghiệm');
    
    Timer(const Duration(seconds: 2), () async {
      await tts.setVolume(voiceVol);
      await tts.speak('Đây là giọng nữ thử nghiệm');
    });
    
    Timer(const Duration(seconds: 4), () async {
      await tts.setVolume(voiceVol);
      await tts.setPitch(0.3);
      await tts.speak('Đây là giọng robot thử nghiệm');
      
      Timer(const Duration(seconds: 8), () async {
        try {
          if (testPlayer != null && testPlayer.playing) {
            await testPlayer.stop();
            activePlayers.remove(testPlayer);
            await testPlayer.dispose();
          }
        } catch (_) {}
      });
    });
  }

  Future<void> pickMp3ForEvent(int eventIndex, int weekdayIndex) async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      
      if (res != null && res.files.single.path != null) {
        setState(() {
          events[eventIndex].mp3ByWeekday[weekdayIndex] = res.files.single.path!;
        });
        await _saveEvents();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi chọn file: $e')),
        );
      }
    }
  }

  Future<void> toggleEvent(int index, bool val) async {
    setState(() {
      events[index].enabled = val;
      if (!val) events[index].completed = false;
    });
    
    await _saveEvents();
    _scheduleAllEvents();
    
    if (events.any((e) => e.enabled)) {
      await _startSilentLoopIfNeeded();
    } else {
      try {
        await audioPlayer.pause();
        silentLoopOn = false;
      } catch (_) {}
    }
  }

  Future<void> addManualEvent() async {
    final now = DateTime.now();
    events.add(EventItem(
      hour: now.hour,
      minute: (now.minute + 5) % 60,
      title: 'Sự kiện mới',
    ));
    await _saveEvents();
    setState(() {});
    _scheduleAllEvents();
  }

  Future<void> deleteEvent(int index) async {
    setState(() {
      events.removeAt(index);
    });
    await _saveEvents();
    _scheduleAllEvents();
  }

  Widget _buildWeekdayChips(EventItem e, int eventIndex) {
    final labels = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];
    return Wrap(
      spacing: 4,
      children: List.generate(7, (i) {
        return ChoiceChip(
          label: Text(labels[i]),
          selected: e.weekdays[i],
          onSelected: (v) async {
            setState(() => e.weekdays[i] = v);
            await _saveEvents();
            _scheduleAllEvents();
          },
        );
      }),
    );
  }

  Widget _buildEventCard(EventItem e, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: e.completed,
                  onChanged: e.isOverdue ? (v) => toggleComplete(index) : null,
                ),
                Expanded(
                  child: Text(
                    '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')} - ${e.title}',
                    style: TextStyle(
                      fontSize: 16,
                      decoration: e.completed ? TextDecoration.lineThrough : TextDecoration.none,
                      color: e.completed ? Colors.grey : Colors.black,
                    ),
                  ),
                ),
                Switch(
                  value: e.enabled,
                  onChanged: (v) => toggleEvent(index, v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => deleteEvent(index),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            _buildWeekdayChips(e, index),
            const SizedBox(height: 8),
            
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(7, (d) {
                  final hasMp3 = e.mp3ByWeekday[d] != null;
                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    child: ElevatedButton(
                      onPressed: () => pickMp3ForEvent(index, d),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: hasMp3 ? Colors.green : Colors.blue,
                      ),
                      child: Text(
                        'Âm ${d + 1}',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                }),
              ),
            ),
            
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton(
                  onPressed: () => testAlarmMix(
                    e.mp3ByWeekday.firstWhere((x) => x != null, orElse: () => null),
                    musicVol: musicVolume,
                    voiceVol: voiceVolume,
                  ),
                  child: const Text('Test Âm thanh'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => playAlarm(index, 0),
                  child: const Text('Phát ngay'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AlasAll',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('AlasAll - Báo thức thông minh'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Cài đặt âm lượng'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const Text('Âm nhạc:'),
                            Expanded(
                              child: Slider(
                                value: musicVolume,
                                onChanged: (v) => setState(() => musicVolume = v),
                                min: 0,
                                max: 1,
                              ),
                            ),
                            Text('${(musicVolume * 100).toInt()}%'),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Giọng nói:'),
                            Expanded(
                              child: Slider(
                                value: voiceVolume,
                                onChanged: (v) => setState(() => voiceVolume = v),
                                min: 0,
                                max: 1,
                              ),
                            ),
                            Text('${(voiceVolume * 100).toInt()}%'),
                          ],
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: importTxt,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Import TXT'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: addManualEvent,
                          icon: const Icon(Icons.add),
                          label: const Text('Thêm mới'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Định dạng TXT: hh.mm: Sự kiện (ví dụ: 8.30: Thức dậy)',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ),
            ),
            
            Expanded(
              child: events.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.alarm, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text('Chưa có sự kiện nào'),
                          Text('Hãy import file TXT hoặc thêm thủ công'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (context, index) => _buildEventCard(events[index], index),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
