import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';


// https://api.clockify.me/api/v1/workspaces/659ff08fb7ad213c9ab6f37b/user/66e3d616e7d56d567fe7cdc9/time-entries?start=2025-05-07T18:30:00.000Z&end=2025-05-08T18:29:59.999Z
// https://api.clockify.me/api/v1/workspaces/659ff08fb7ad213c9ab6f37b/user/66e3d616e7d56d567fe7cdc9/time-entries?start=2025-05-07T13:00:00Z&end=2025-05-08T12:59:59Z
// https://api.clockify.me/api/v1/workspaces/659ff08fb7ad213c9ab6f37b/user/66e3d616e7d56d567fe7cdc9/time-entries?start=2025-05-07T13:00:00.000+0000&end=2025-05-08T12:59:59.000+0000
void main() async {
  // Load environment variables
  await dotenv.load(fileName: '.env');
  
  // Initialize timezone data
  tz_data.initializeTimeZones();
  
  // Configure for web
  setUrlStrategy(PathUrlStrategy());
  
  runApp(const ClockifyApp());
}

class ClockifyApp extends StatelessWidget {
  const ClockifyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Clockify Work Sessions',
     theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.grey[900],
        cardColor: Colors.grey[850],
        dialogBackgroundColor: Colors.grey[800],
        colorScheme: const ColorScheme.dark().copyWith(
          primary: Colors.blue,
          secondary: Colors.blueAccent,
        ),
      ),
      themeMode:ThemeMode.dark ,
      home: const ClockifyHomePage(),
    );
  }
}

class ClockifyHomePage extends StatefulWidget {
  const ClockifyHomePage({Key? key}) : super(key: key);

  @override
  State<ClockifyHomePage> createState() => _ClockifyHomePageState();
}

class _ClockifyHomePageState extends State<ClockifyHomePage> {
  DateTime _selectedDate = DateTime.now();
  String _resultText = '';
  bool _isLoading = false;
    bool _isConfigured = false;


   // Controllers for text fields
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _workspaceIdController = TextEditingController();
  final TextEditingController _userIdController = TextEditingController();


  // Timezone settings
  final tz.Location _istTimezone = tz.getLocation('Asia/Kolkata');
  final tz.Location _utcTimezone = tz.getLocation('UTC');

  // API keys and IDs
  late String _apiKey;
  late String _workspaceId;
  late String _userId;
  final String _jiraBaseUrl = 'https://timesmart.atlassian.net/browse/';

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }
 @override
  void dispose() {
    _apiKeyController.dispose();
    _workspaceIdController.dispose();
    _userIdController.dispose();
    super.dispose();
  }
  
  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    
    setState(() {
      _apiKey = prefs.getString('api_key') ?? '';
      _workspaceId = prefs.getString('workspace_id') ?? '';
      _userId = prefs.getString('user_id') ?? '';
      
      _apiKeyController.text = _apiKey;
      _workspaceIdController.text = _workspaceId;
      _userIdController.text = _userId;
      
      _isConfigured = _apiKey.isNotEmpty && _workspaceId.isNotEmpty && _userId.isNotEmpty;
    });
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    
    String apiKey = _apiKeyController.text.trim();
    String workspaceId = _workspaceIdController.text.trim();
    String userId = _userIdController.text.trim();
    
    if (apiKey.isEmpty || workspaceId.isEmpty || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All fields are required')),
      );
      return;
    }
    
    await prefs.setString('api_key', apiKey);
    await prefs.setString('workspace_id', workspaceId);
    await prefs.setString('user_id', userId);
    
    setState(() {
      _apiKey = apiKey;
      _workspaceId = workspaceId;
      _userId = userId;
      _isConfigured = true;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved successfully')),
    );
  }

  void _loadEnvVariables() {
    _apiKey = dotenv.env['API_KEY'] ?? '';
    _workspaceId = dotenv.env['WORKSPACE_ID'] ?? '';
    _userId = dotenv.env['USER_ID'] ?? '';
    
    if (_apiKey.isEmpty || _workspaceId.isEmpty || _userId.isEmpty) {
      setState(() {
        _resultText = 'Error: Missing environment variables. Please check your .env file.';
      });
    }
  }

  DateTime? _parseTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) {
      return null;
    }
    
    DateTime utcTime = DateTime.parse(timestamp);
    // Convert UTC to IST
    var istTime = tz.TZDateTime.from(utcTime, _utcTimezone).add(
      const Duration(hours: 5, minutes: 30) // IST is UTC+5:30
    );
    
    return istTime;
  }

  String _extractTicketInfo(String description) {
    RegExp regex = RegExp(r'\b[A-Z]+-\d+\b');
    Match? match = regex.firstMatch(description);
    
    if (match != null) {
      String ticketId = match.group(0)!;
      String restOfDescription = description.replaceFirst(ticketId, '').trim();
      String jiraLink = '$_jiraBaseUrl$ticketId';
      
      return '$jiraLink\n$restOfDescription'.trim();
    }
    
    return description.trim();
  }

  List<List<dynamic>> _analyzeWorkSessions(List<Map<String, dynamic>> entries) {
    List<List<dynamic>> result = [];
    List<List<dynamic>> workDurations = [];
    List<List<dynamic>> breakDurations = [];
    
    List<List<dynamic>> sessions = [];
    
    for (var entry in entries) {
      DateTime? start = _parseTime(entry['timeInterval']['start']);
      DateTime? end = _parseTime(entry['timeInterval']['end']);
      String description = _extractTicketInfo(entry['description'] ?? 'No Description');
      
      if (start != null && end != null) {
        sessions.add([start, end, description]);
      }
    }
    
    sessions.sort((a, b) => (a[0] as DateTime).compareTo(b[0] as DateTime));
    
    for (int i = 0; i < sessions.length; i++) {
      DateTime start = sessions[i][0] as DateTime;
      DateTime end = sessions[i][1] as DateTime;
      String description = sessions[i][2] as String;
      
      workDurations.add([start, end, description]);
      
      if (i > 0) {
        DateTime prevEnd = sessions[i - 1][1] as DateTime;
        if (start.isAfter(prevEnd)) {
          breakDurations.add([prevEnd, start]);
        }
      }
    }
    
    result.add(workDurations);
    result.add(breakDurations);
    
    return result;
  }
Future<void> _fetchWorkSessions() async {
    if (!_isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please configure API settings first')),
      );
      return;
    }
    setState(() {
      _isLoading = true;
      _resultText = 'Loading...';
    });
    
    try {
      tz.TZDateTime istStart = tz.TZDateTime(
        _istTimezone, 
        _selectedDate.year, 
        _selectedDate.month, 
        _selectedDate.day, 
        0, 0, 0
      );
      
      tz.TZDateTime istEnd = tz.TZDateTime(
        _istTimezone, 
        _selectedDate.year, 
        _selectedDate.month, 
        _selectedDate.day, 
        23, 59, 59
      );
      
      // Convert IST to UTC
      tz.TZDateTime utcStart = tz.TZDateTime.from(istStart, _utcTimezone).subtract(
        const Duration(hours: 5, minutes: 30) // Convert from IST to UTC
      );
      tz.TZDateTime utcEnd = tz.TZDateTime.from(istEnd, _utcTimezone).subtract(
        const Duration(hours: 5, minutes: 30) // Convert from IST to UTC
      );
      
      // Format dates properly for Clockify API
      // API requires ISO 8601 format with Z suffix: "yyyy-MM-ddThh:mm:ssZ"
      String formattedUtcStart = "${utcStart.year}-"
          "${utcStart.month.toString().padLeft(2, '0')}-"
          "${utcStart.day.toString().padLeft(2, '0')}T"
          "${"18".toString().padLeft(2, '0')}:"
          "${"30".toString().padLeft(2, '0')}:"
          "${"00".toString().padLeft(2, '0')}Z";
          // 2025-05-07T18:30:00.000Z&end=2025-05-08T18:29:59.999Z
      String formattedUtcEnd = "${utcEnd.year}-"
          "${utcEnd.month.toString().padLeft(2, '0')}-"
          "${utcEnd.day.toString().padLeft(2, '0')}T"
          "${"18".toString().padLeft(2, '0')}:"
          "${"29".toString().padLeft(2, '0')}:"
          "${"59".toString().padLeft(2, '0')}Z";
      
      Map<String, String> headers = {
        'X-Api-Key': _apiKey,
        'Content-Type': 'application/json'
      };
      
      String url = 'https://api.clockify.me/api/v1/workspaces/$_workspaceId/user/$_userId/time-entries?start=$formattedUtcStart&end=$formattedUtcEnd';
      
      // Print URL for debugging
      debugPrint('API URL: $url');
      
      http.Response response = await http.get(Uri.parse(url), headers: headers);
      
      if (response.statusCode == 200) {
        List<dynamic> timeEntries = json.decode(response.body);
        
        if (timeEntries.isEmpty) {
          setState(() {
            _resultText = 'No time entries found for selected date.';
            _isLoading = false;
          });
          return;
        }
        
        List<Map<String, dynamic>> timeEntriesData = timeEntries.map((entry) => {
          'timeInterval': entry['timeInterval'],
          'description': entry['description'] ?? 'No Description'
        }).toList();
        
        List<List<dynamic>> analyzed = _analyzeWorkSessions(timeEntriesData);
        List<List<dynamic>> workDurations = analyzed[0] as List<List<dynamic>>;
        List<List<dynamic>> breakDurations = analyzed[1] as List<List<dynamic>>;
        
        // Format and display data
        String resultText = "📌 Work Sessions:\n";
        
        for (var duration in workDurations) {
          DateTime start = duration[0] as DateTime;
          DateTime end = duration[1] as DateTime;
          String description = duration[2] as String;
          
          String startTime = DateFormat('HH:mm').format(start);
          String endTime = DateFormat('HH:mm').format(end);
          
          resultText += "$description\n\n$startTime - $endTime\n\n";
        }
        
        resultText += "☕ Non-Working Hours:\n";
        
        for (var duration in breakDurations) {
          DateTime start = duration[0] as DateTime;
          DateTime end = duration[1] as DateTime;
          
          String startTime = DateFormat('HH:mm').format(start);
          String endTime = DateFormat('HH:mm').format(end);
          
          resultText += "($startTime - $endTime)\n";
        }
        
        setState(() {
          _resultText = resultText.trim();
          _isLoading = false;
        });
      } else {
        setState(() {
          _resultText = 'Error: ${response.statusCode} - ${response.body}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _resultText = 'Error: $e';
        _isLoading = false;
      });
    }
  }
  // Future<void> _fetchWorkSessions() async {
  //   setState(() {
  //     _isLoading = true;
  //     _resultText = 'Loading...';
  //   });
    
  //   try {
  //     tz.TZDateTime istStart = tz.TZDateTime(
  //       _istTimezone, 
  //       _selectedDate.year, 
  //       _selectedDate.month, 
  //       _selectedDate.day, 
  //       0, 0, 0
  //     );
      
  //     tz.TZDateTime istEnd = tz.TZDateTime(
  //       _istTimezone, 
  //       _selectedDate.year, 
  //       _selectedDate.month, 
  //       _selectedDate.day, 
  //       23, 59, 59
  //     );
      
  //     // Convert IST to UTC
  //     tz.TZDateTime utcStart = tz.TZDateTime.from(istStart, _utcTimezone).subtract(
  //       const Duration(hours: 5, minutes: 30) // Convert from IST to UTC
  //     );
  //     tz.TZDateTime utcEnd = tz.TZDateTime.from(istEnd, _utcTimezone).subtract(
  //       const Duration(hours: 5, minutes: 30) // Convert from IST to UTC
  //     );
      
  //     String formattedUtcStart = utcStart.toIso8601String();
  //     String formattedUtcEnd = utcEnd.toIso8601String();
      
  //     Map<String, String> headers = {
  //       'X-Api-Key': _apiKey,
  //     };
      
  //     String url = 'https://api.clockify.me/api/v1/workspaces/$_workspaceId/user/$_userId/time-entries?start=$formattedUtcStart&end=$formattedUtcEnd';
      
  //     http.Response response = await http.get(Uri.parse(url), headers: headers);
      
  //     if (response.statusCode == 200) {
  //       List<dynamic> timeEntries = json.decode(response.body);
  //       List<Map<String, dynamic>> timeEntriesData = timeEntries.map((entry) => {
  //         'timeInterval': entry['timeInterval'],
  //         'description': entry['description'] ?? 'No Description'
  //       }).toList();
        
  //       List<List<dynamic>> analyzed = _analyzeWorkSessions(timeEntriesData);
  //       List<List<dynamic>> workDurations = analyzed[0] as List<List<dynamic>>;
  //       List<List<dynamic>> breakDurations = analyzed[1] as List<List<dynamic>>;
        
  //       // Format and display data
  //       String resultText = "📌 Work Sessions:\n";
        
  //       for (var duration in workDurations) {
  //         DateTime start = duration[0] as DateTime;
  //         DateTime end = duration[1] as DateTime;
  //         String description = duration[2] as String;
          
  //         String startTime = DateFormat('HH:mm').format(start);
  //         String endTime = DateFormat('HH:mm').format(end);
          
  //         resultText += "$description\n\n$startTime - $endTime\n\n";
  //       }
        
  //       resultText += "☕ Non-Working Hours:\n";
        
  //       for (var duration in breakDurations) {
  //         DateTime start = duration[0] as DateTime;
  //         DateTime end = duration[1] as DateTime;
          
  //         String startTime = DateFormat('HH:mm').format(start);
  //         String endTime = DateFormat('HH:mm').format(end);
          
  //         resultText += "($startTime - $endTime)\n";
  //       }
        
  //       setState(() {
  //         _resultText = resultText.trim();
  //         _isLoading = false;
  //       });
  //     } else {
  //       setState(() {
  //         _resultText = 'Error: ${response.statusCode} - Unable to fetch data.';
  //         _isLoading = false;
  //       });
  //     }
  //   } catch (e) {
  //     setState(() {
  //       _resultText = 'Error: $e';
  //       _isLoading = false;
  //     });
  //   }
  // }

 
  void _copyToClipboard() {
    if (_resultText.isNotEmpty && _resultText != 'Loading...') {
      Clipboard.setData(ClipboardData(text: _resultText));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to copy')),
      );
    }
  }

   void _clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.remove('api_key');
    await prefs.remove('workspace_id');
    await prefs.remove('user_id');
    
    setState(() {
      _apiKey = '';
      _workspaceId = '';
      _userId = '';
      _apiKeyController.text = '';
      _workspaceIdController.text = '';
      _userIdController.text = '';
      _isConfigured = false;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings cleared')),
    );
  }
 Widget _buildSettingsDialog() {
    return AlertDialog(
      title: const Text('API Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'Enter your Clockify API Key',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _workspaceIdController,
              decoration: const InputDecoration(
                labelText: 'Workspace ID',
                hintText: 'Enter your Clockify Workspace ID',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userIdController,
              decoration: const InputDecoration(
                labelText: 'User ID',
                hintText: 'Enter your Clockify User ID',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _clearCredentials,
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            _saveCredentials();
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
   appBar: AppBar(
        title: const Text('Clockify Work Sessions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => _buildSettingsDialog(),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Select Date:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TableCalendar(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _selectedDate,
              calendarFormat: CalendarFormat.month,
              selectedDayPredicate: (day) {
                return isSameDay(_selectedDate, day);
              },
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDate = selectedDay;
                });
              },
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _fetchWorkSessions,
              child: _isLoading 
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text('Get Work Sessions'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(_resultText),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _copyToClipboard,
              child: const Text('Copy to Clipboard'),
            ),
          ],
        ),
      ),
    );
  }
}