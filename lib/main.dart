import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const BreathTrackApp());
}

class BreathTrackApp extends StatelessWidget {
  const BreathTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BreathTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F2FE),
          secondary: Color(0xFFD946EF),
          surface: Color(0xFF1E293B),
          background: Color(0xFF0B0F19),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF151F32),
          elevation: 0,
        ),
      ),
      home: const BreathingTrackerHome(),
    );
  }
}

/// Model class to store completed breath cycles for history and statistics.
class BreathCycle {
  final DateTime startTime;
  final DateTime peakTime;
  final DateTime endTime;
  final Duration inhaleDuration;
  final Duration exhaleDuration;
  final double bpm;

  BreathCycle({
    required this.startTime,
    required this.peakTime,
    required this.endTime,
    required this.inhaleDuration,
    required this.exhaleDuration,
    required this.bpm,
  });

  Duration get totalDuration => endTime.difference(startTime);
}

class BreathingTrackerHome extends StatefulWidget {
  const BreathingTrackerHome({super.key});

  @override
  State<BreathingTrackerHome> createState() => _BreathingTrackerHomeState();
}

class _BreathingTrackerHomeState extends State<BreathingTrackerHome>
    with SingleTickerProviderStateMixin {
  // Sensor and Tracking Subscriptions
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  Timer? _timer;
  
  // Tracking State
  bool _isTracking = false;
  int _sessionSeconds = 0;
  DateTime? _sessionStartTime;
  
  // Dynamic Axis Selection Variables
  String _activeAxis = 'Z'; // 'X', 'Y', or 'Z'
  double _meanX = 0.0;
  double _meanY = 0.0;
  double _meanZ = 0.0;
  double _varX = 0.0;
  double _varY = 0.0;
  double _varZ = 0.0;
  int _axisSelectionCounter = 0;
  
  // Filtering variables
  double _filteredVal = 0.0;
  double _baselineVal = 0.0;
  final double _alphaLP = 0.12; // Low-pass filter smoothing coefficient
  final double _alphaBaseline = 0.004; // Baseline tracker smoothing coefficient
  
  // Peak/Valley Detection variables
  String _currentPhase = 'HOLDING'; // 'INHALING', 'EXHALING', 'HOLDING'
  double _localMax = 0.0;
  double _localMin = 0.0;
  DateTime? _timeOfMax;
  DateTime? _timeOfMin;
  DateTime? _lastValleyTime;
  DateTime? _lastPeakTime;
  
  // Calculated metrics
  double _lastInhaleSec = 0.0;
  double _lastExhaleSec = 0.0;
  double _bpm = 0.0;
  final List<double> _recentBpmList = [];
  final List<BreathCycle> _breathHistory = [];
  
  // Graph Buffer (Stores last 250 points, approx 5 seconds at 50Hz)
  final List<double> _chartBuffer = [];
  final List<double> _recentDetrendedBuffer = [];
  final int _maxChartPoints = 200;
  
  // Throttling UI updates to maintain 60FPS and reduce overhead
  DateTime _lastUiUpdateTime = DateTime.now();

  // Visual Breathing Pacer (Resonant Breathing Guide)
  bool _pacerEnabled = false;
  double _pacerInhaleSec = 4.0; // Default target inhale: 4 seconds
  double _pacerExhaleSec = 5.0; // Default target exhale: 5 seconds
  late AnimationController _pacerController;
  
  // Real-time phase tracking timer
  DateTime? _phaseStartTime;

  // User settings
  String _sensitivity = 'Medium'; // 'High', 'Medium', 'Low'
  String _axisOverride = 'Auto'; // 'Auto', 'Force X', 'Force Y', 'Force Z'

  @override
  void initState() {
    super.initState();
    // Initialize Pacer Controller (runs forward from 0.0 to 1.0 continuously)
    double totalCycleSec = _pacerInhaleSec + _pacerExhaleSec;
    _pacerController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (totalCycleSec * 1000).round()),
    );
    _pacerController.repeat(reverse: false);
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _timer?.cancel();
    _pacerController.dispose();
    super.dispose();
  }

  // Resets all tracking variables
  void _resetTrackingData() {
    _sessionSeconds = 0;
    _meanX = 0.0;
    _meanY = 0.0;
    _meanZ = 0.0;
    _varX = 0.0;
    _varY = 0.0;
    _varZ = 0.0;
    _axisSelectionCounter = 0;
    _filteredVal = 0.0;
    _baselineVal = 0.0;
    _currentPhase = 'HOLDING';
    _localMax = 0.0;
    _localMin = 0.0;
    _timeOfMax = null;
    _timeOfMin = null;
    _lastValleyTime = null;
    _lastPeakTime = null;
    _lastInhaleSec = 0.0;
    _lastExhaleSec = 0.0;
    _bpm = 0.0;
    _recentBpmList.clear();
    _breathHistory.clear();
    _chartBuffer.clear();
    _recentDetrendedBuffer.clear();
    _phaseStartTime = null;
  }

  void _startTracking() {
    setState(() {
      _resetTrackingData();
      _isTracking = true;
      _sessionStartTime = DateTime.now();
      _lastValleyTime = DateTime.now(); // Baseline starting reference
      _phaseStartTime = DateTime.now();
    });

    // Start session timer
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _sessionSeconds++;
      });
    });

    // Determine min delta based on sensitivity settings
    double getMinDelta() {
      switch (_sensitivity) {
        case 'High':
          return 0.02; // Very sensitive to small movements
        case 'Low':
          return 0.08; // Less sensitive, filters more movement
        case 'Medium':
        default:
          return 0.04;
      }
    }

    // Subscribe to accelerometer events
    _accelSubscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!_isTracking) return;

      // 1. Dynamic axis baseline and variance calculations
      _meanX = 0.02 * event.x + 0.98 * _meanX;
      double dx = event.x - _meanX;
      _varX = 0.01 * (dx * dx) + 0.99 * _varX;

      _meanY = 0.02 * event.y + 0.98 * _meanY;
      double dy = event.y - _meanY;
      _varY = 0.01 * (dy * dy) + 0.99 * _varY;

      _meanZ = 0.02 * event.z + 0.98 * _meanZ;
      double dz = event.z - _meanZ;
      _varZ = 0.01 * (dz * dz) + 0.99 * _varZ;

      // 2. Select the active tracking axis
      if (_axisOverride == 'Auto') {
        _axisSelectionCounter++;
        if (_axisSelectionCounter >= 100) { // Evaluate every ~2 seconds (at 50Hz)
          _axisSelectionCounter = 0;
          String newAxis = _activeAxis;
          double maxVar = _varX;
          newAxis = 'X';

          if (_varY > maxVar) {
            maxVar = _varY;
            newAxis = 'Y';
          }
          if (_varZ > maxVar) {
            maxVar = _varZ;
            newAxis = 'Z';
          }

          // Switch axis if the new axis has significantly more motion/tilt (with 50% hysteresis)
          double currentVar = (_activeAxis == 'X') ? _varX : ((_activeAxis == 'Y') ? _varY : _varZ);
          if (newAxis != _activeAxis && maxVar > currentVar * 1.5) {
            _activeAxis = newAxis;
            // Smooth transition: seed filters with the new axis values
            double newRaw = (_activeAxis == 'X') ? event.x : ((_activeAxis == 'Y') ? event.y : event.z);
            _filteredVal = newRaw;
            _baselineVal = newRaw;
            _recentDetrendedBuffer.clear();
            _currentPhase = 'HOLDING';
            _phaseStartTime = DateTime.now();
          }
        }
      } else {
        _activeAxis = _axisOverride.replaceAll('Force ', '');
      }

      // 3. Extract active signal
      double rawVal = (_activeAxis == 'X') ? event.x : ((_activeAxis == 'Y') ? event.y : event.z);

      // 4. Low-pass filter (exponential moving average) to remove sensor noise and muscle jitter
      _filteredVal = _alphaLP * rawVal + (1.0 - _alphaLP) * _filteredVal;

      // 5. High-pass filter via detrending (subtract slow baseline to adapt to posture shifts)
      _baselineVal = _alphaBaseline * _filteredVal + (1.0 - _alphaBaseline) * _baselineVal;
      double detrendedVal = _filteredVal - _baselineVal;

      // 6. Push to chart buffers
      _chartBuffer.add(detrendedVal);
      if (_chartBuffer.length > _maxChartPoints) {
        _chartBuffer.removeAt(0);
      }

      _recentDetrendedBuffer.add(detrendedVal);
      if (_recentDetrendedBuffer.length > 150) { // Sliding 3-second window
        _recentDetrendedBuffer.removeAt(0);
      }

      // 7. Dynamic threshold (hysteresis delta) calculation based on recent signal range
      double minDelta = getMinDelta();
      double currentRange = 0.0;
      if (_recentDetrendedBuffer.isNotEmpty) {
        double maxInWindow = _recentDetrendedBuffer.reduce(math.max);
        double minInWindow = _recentDetrendedBuffer.reduce(math.min);
        currentRange = maxInWindow - minInWindow;
      }
      // Hysteresis is 18% of recent peak-to-peak amplitude, bounded by sensitivity minDelta
      double delta = math.max(minDelta, currentRange * 0.18);

      // 8. Real-time Peak and Valley detection state machine
      DateTime now = DateTime.now();
      bool stateChanged = false;

      if (_currentPhase == 'HOLDING') {
        if (detrendedVal > delta) {
          _currentPhase = 'INHALING';
          _localMax = detrendedVal;
          _timeOfMax = now;
          _lastValleyTime = now;
          _phaseStartTime = now;
          stateChanged = true;
        } else if (detrendedVal < -delta) {
          _currentPhase = 'EXHALING';
          _localMin = detrendedVal;
          _timeOfMin = now;
          _lastPeakTime = now;
          _phaseStartTime = now;
          stateChanged = true;
        }
      } else if (_currentPhase == 'INHALING') {
        if (detrendedVal > _localMax) {
          _localMax = detrendedVal;
          _timeOfMax = now;
        } else if (detrendedVal < _localMax - delta) {
          // Check refractory period: breathing phase must last at least 800ms to filter noise
          int timeSinceLastValley = _lastValleyTime != null ? now.difference(_lastValleyTime!).inMilliseconds : 1000;
          if (timeSinceLastValley > 800) {
            // Peak detected -> Transition to Exhaling
            _currentPhase = 'EXHALING';
            _timeOfMin = now;
            _localMin = detrendedVal;
            
            DateTime peakTime = _timeOfMax ?? now;
            if (_lastValleyTime != null) {
              double duration = peakTime.difference(_lastValleyTime!).inMilliseconds / 1000.0;
              if (duration >= 0.8 && duration <= 10.0) {
                _lastInhaleSec = duration;
              }
            }
            _lastPeakTime = peakTime;
            _phaseStartTime = now;
            stateChanged = true;
            HapticFeedback.lightImpact(); // Subtle vibration feedback
          }
        }
      } else if (_currentPhase == 'EXHALING') {
        if (detrendedVal < _localMin) {
          _localMin = detrendedVal;
          _timeOfMin = now;
        } else if (detrendedVal > _localMin + delta) {
          // Check refractory period
          int timeSinceLastPeak = _lastPeakTime != null ? now.difference(_lastPeakTime!).inMilliseconds : 1000;
          if (timeSinceLastPeak > 800) {
            // Valley detected -> Transition to Inhaling
            _currentPhase = 'INHALING';
            _timeOfMax = now;
            _localMax = detrendedVal;
            
            DateTime valleyTime = _timeOfMin ?? now;
            if (_lastPeakTime != null) {
              double duration = valleyTime.difference(_lastPeakTime!).inMilliseconds / 1000.0;
              if (duration >= 0.8 && duration <= 10.0) {
                _lastExhaleSec = duration;
              }
            }

            // Complete breath cycle: Valley-to-Valley duration
            if (_lastValleyTime != null) {
              double cycleDuration = valleyTime.difference(_lastValleyTime!).inMilliseconds / 1000.0;
              // Validate breathing rate: 3 to 30 breaths per minute is realistic
              if (cycleDuration >= 2.0 && cycleDuration <= 20.0) {
                double instantaneousBpm = 60.0 / cycleDuration;
                _recentBpmList.add(instantaneousBpm);
                if (_recentBpmList.length > 3) {
                  _recentBpmList.removeAt(0);
                }
                // Smooth BPM using moving average of last 3 cycles
                _bpm = _recentBpmList.reduce((a, b) => a + b) / _recentBpmList.length;

                // Record breath cycle to history
                _breathHistory.add(BreathCycle(
                  startTime: _lastValleyTime!,
                  peakTime: _lastPeakTime ?? valleyTime.subtract(Duration(milliseconds: (_lastExhaleSec * 1000).round())),
                  endTime: valleyTime,
                  inhaleDuration: Duration(milliseconds: (_lastInhaleSec * 1000).round()),
                  exhaleDuration: Duration(milliseconds: (_lastExhaleSec * 1000).round()),
                  bpm: instantaneousBpm,
                ));
              }
            }

            _lastValleyTime = valleyTime;
            _phaseStartTime = now;
            stateChanged = true;
            HapticFeedback.mediumImpact(); // Distinct vibration feedback at end of exhale
          }
        }
      }

      // 9. Throttle UI updates to 30Hz to preserve battery, except on state changes
      DateTime uiNow = DateTime.now();
      if (stateChanged || uiNow.difference(_lastUiUpdateTime).inMilliseconds > 33) {
        setState(() {});
        _lastUiUpdateTime = uiNow;
      }
    });
  }

  void _stopTracking() {
    _timer?.cancel();
    _accelSubscription?.cancel();
    setState(() {
      _isTracking = false;
    });
    _showSummaryDialog();
  }

  // Calculates stats and shows summary dialog
  void _showSummaryDialog() {
    if (_breathHistory.isEmpty) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Session Finished'),
          content: const Text('Not enough breathing data was recorded. Try placing the phone flat on your stomach and keeping still.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Color(0xFF00F2FE))),
            ),
          ],
        ),
      );
      return;
    }

    // Calculations
    int totalBreaths = _breathHistory.length;
    double avgBpm = _breathHistory.map((b) => b.bpm).reduce((a, b) => a + b) / totalBreaths;
    
    double totalInhaleMs = _breathHistory.map((b) => b.inhaleDuration.inMilliseconds).reduce((a, b) => a + b).toDouble();
    double totalExhaleMs = _breathHistory.map((b) => b.exhaleDuration.inMilliseconds).reduce((a, b) => a + b).toDouble();
    double avgInhale = (totalInhaleMs / totalBreaths) / 1000.0;
    double avgExhale = (totalExhaleMs / totalBreaths) / 1000.0;

    // Calculate Consistency (Standard Deviation of Cycle Durations)
    double meanDuration = _breathHistory.map((b) => b.totalDuration.inMilliseconds).reduce((a, b) => a + b) / totalBreaths;
    double varianceSum = 0.0;
    for (var breath in _breathHistory) {
      double diff = breath.totalDuration.inMilliseconds - meanDuration;
      varianceSum += diff * diff;
    }
    double stdDevSeconds = math.sqrt(varianceSum / totalBreaths) / 1000.0;
    
    String consistency;
    Color consistencyColor;
    if (stdDevSeconds < 0.4) {
      consistency = 'Excellent';
      consistencyColor = const Color(0xFF10B981); // Emerald Green
    } else if (stdDevSeconds < 1.0) {
      consistency = 'Good';
      consistencyColor = const Color(0xFF3B82F6); // Blue
    } else {
      consistency = 'Variable';
      consistencyColor = const Color(0xFFF59E0B); // Amber
    }

    // Personalized relaxation tips based on average BPM
    String feedbackTip;
    if (avgBpm <= 7) {
      feedbackTip = "Outstanding! You are in a state of deep, resonant breathing, which maximizes heart rate variability and deeply calms the nervous system.";
    } else if (avgBpm <= 12) {
      feedbackTip = "Great job! Your breathing is relaxed and controlled. This helps restore balance and reduces everyday stress.";
    } else {
      feedbackTip = "Your breathing was a bit rapid. Try exhaling longer than you inhale (e.g. 4s inhale, 6s exhale) to slow your heart rate down.";
    }

    // Format Session Duration
    int minutes = _sessionSeconds ~/ 60;
    int seconds = _sessionSeconds % 60;
    String durationString = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF131B2E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Color(0xFF1E293B), width: 1.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Session Summary',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 2x2 Grid for Session Metrics
                      GridView.count(
                        shrinkWrap: true,
                        crossAxisCount: 2,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        childAspectRatio: 1.5,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _buildSummaryCard('Session Duration', durationString, Icons.timer, const Color(0xFF3B82F6)),
                          _buildSummaryCard('Total Breaths', '$totalBreaths', Icons.air, const Color(0xFF00F2FE)),
                          _buildSummaryCard('Average BPM', '${avgBpm.toStringAsFixed(1)} BPM', Icons.favorite, const Color(0xFFD946EF)),
                          _buildSummaryCard('Consistency', consistency, Icons.analytics, consistencyColor),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Inhale/Exhale breakdown bar
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Average Breath Phase Ratio',
                              style: TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  flex: (avgInhale * 10).round(),
                                  child: Container(
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(colors: [Color(0xFF00F2FE), Color(0xFF4FACFE)]),
                                      borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
                                    ),
                                    child: Text('${avgInhale.toStringAsFixed(1)}s', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
                                  ),
                                ),
                                Expanded(
                                  flex: (avgExhale * 10).round(),
                                  child: Container(
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(colors: [Color(0xFFF43F5E), Color(0xFFD946EF)]),
                                      borderRadius: BorderRadius.horizontal(right: Radius.circular(12)),
                                    ),
                                    child: Text('${avgExhale.toStringAsFixed(1)}s', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.arrow_upward, size: 12, color: Color(0xFF00F2FE)),
                                    SizedBox(width: 4),
                                    Text('Inhale', style: TextStyle(fontSize: 11, color: Colors.white60)),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Text('Exhale', style: TextStyle(fontSize: 11, color: Colors.white60)),
                                    SizedBox(width: 4),
                                    Icon(Icons.arrow_downward, size: 12, color: Color(0xFFD946EF)),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Feedback Banner
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF1E293B),
                              const Color(0xFF151F32).withOpacity(0.5),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF00F2FE).withOpacity(0.1)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.spa, color: Color(0xFF00F2FE), size: 24),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                feedbackTip,
                                style: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xCCFFFFFF)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Breath-by-Breath Duration Log
                      const Text(
                        'Breath-by-Breath Log',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _breathHistory.length,
                        itemBuilder: (context, index) {
                          final cycle = _breathHistory[index];
                          final startSec = cycle.startTime.difference(_sessionStartTime!).inMilliseconds / 1000.0;
                          final peakSec = cycle.peakTime.difference(_sessionStartTime!).inMilliseconds / 1000.0;
                          final endSec = cycle.endTime.difference(_sessionStartTime!).inMilliseconds / 1000.0;
                          
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.03)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Breath #${index + 1}',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${cycle.bpm.toStringAsFixed(1)} BPM',
                                      style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4)),
                                    ),
                                  ],
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.arrow_upward, size: 10, color: Color(0xFF00F2FE)),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Inhale: ${startSec.round()}-${peakSec.round()}s',
                                          style: const TextStyle(fontSize: 11, color: Colors.white70),
                                        ),
                                        Text(
                                          ' (${(cycle.inhaleDuration.inMilliseconds / 1000.0).toStringAsFixed(1)}s)',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00F2FE)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.arrow_downward, size: 10, color: Color(0xFFD946EF)),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Exhale: ${peakSec.round()}-${endSec.round()}s',
                                          style: const TextStyle(fontSize: 11, color: Colors.white70),
                                        ),
                                        Text(
                                          ' (${(cycle.exhaleDuration.inMilliseconds / 1000.0).toStringAsFixed(1)}s)',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFD946EF)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Close Button
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                ),
                child: const Text('Close Session', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryCard(String label, String value, IconData icon, Color accentColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // Opens settings overlay sheet
  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF131B2E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(color: Color(0xFF1E293B), width: 1.5),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Settings & Optimization',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),

                  // Sensitivity Setting
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Sensitivity Threshold', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('Filters body motion noise', style: TextStyle(fontSize: 12, color: Colors.white60)),
                        ],
                      ),
                      DropdownButton<String>(
                        value: _sensitivity,
                        dropdownColor: const Color(0xFF1E293B),
                        items: ['High', 'Medium', 'Low'].map((String val) {
                          return DropdownMenuItem<String>(
                            value: val,
                            child: Text(val),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() => _sensitivity = val);
                            setState(() => _sensitivity = val);
                          }
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 32, color: Colors.white10),

                  // Axis Selection Setting
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Placement Tracking Axis', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('Keep "Auto" for any phone direction', style: TextStyle(fontSize: 12, color: Colors.white60)),
                        ],
                      ),
                      DropdownButton<String>(
                        value: _axisOverride,
                        dropdownColor: const Color(0xFF1E293B),
                        items: ['Auto', 'Force X', 'Force Y', 'Force Z'].map((String val) {
                          return DropdownMenuItem<String>(
                            value: val,
                            child: Text(val),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() {
                              _axisOverride = val;
                            });
                            setState(() {
                              _axisOverride = val;
                              if (val != 'Auto') {
                                _activeAxis = val.replaceAll('Force ', '');
                              }
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 32, color: Colors.white10),

                  // Visual Pacer Toggle
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Visual Breathing Guide (Pacer)', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('Sync breath with outer ring guide', style: TextStyle(fontSize: 12, color: Colors.white60)),
                        ],
                      ),
                      Switch(
                        value: _pacerEnabled,
                        activeColor: const Color(0xFF00F2FE),
                        onChanged: (val) {
                          setModalState(() => _pacerEnabled = val);
                          setState(() => _pacerEnabled = val);
                        },
                      ),
                    ],
                  ),
                  
                  if (_pacerEnabled) ...[
                    const SizedBox(height: 16),
                    // Show calculated BPM summary
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Calculated Pacer Rate:',
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                          Text(
                            '${(60.0 / (_pacerInhaleSec + _pacerExhaleSec)).toStringAsFixed(1)} BPM',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF00F2FE),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Slider 1: Inhale Duration
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Inhale Duration:', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        Text('${_pacerInhaleSec.round()}s', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00F2FE))),
                      ],
                    ),
                    Slider(
                      value: _pacerInhaleSec,
                      min: 2.0,
                      max: 8.0,
                      divisions: 6,
                      activeColor: const Color(0xFF00F2FE),
                      inactiveColor: Colors.white10,
                      onChanged: (val) {
                        setModalState(() {
                          _pacerInhaleSec = val;
                        });
                        setState(() {
                          _pacerInhaleSec = val;
                          double totalCycleSec = _pacerInhaleSec + _pacerExhaleSec;
                          _pacerController.duration = Duration(milliseconds: (totalCycleSec * 1000).round());
                          _pacerController.repeat(reverse: false);
                        });
                      },
                    ),
                    // Slider 2: Exhale Duration
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Exhale Duration:', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        Text('${_pacerExhaleSec.round()}s', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD946EF))),
                      ],
                    ),
                    Slider(
                      value: _pacerExhaleSec,
                      min: 2.0,
                      max: 8.0,
                      divisions: 6,
                      activeColor: const Color(0xFFD946EF),
                      inactiveColor: Colors.white10,
                      onChanged: (val) {
                        setModalState(() {
                          _pacerExhaleSec = val;
                        });
                        setState(() {
                          _pacerExhaleSec = val;
                          double totalCycleSec = _pacerInhaleSec + _pacerExhaleSec;
                          _pacerController.duration = Duration(milliseconds: (totalCycleSec * 1000).round());
                          _pacerController.repeat(reverse: false);
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Determine gradient theme color based on current breathing state
    Color activeAccentColor;
    String stateTitle;
    IconData stateIcon;

    switch (_currentPhase) {
      case 'INHALING':
        activeAccentColor = const Color(0xFF00F2FE);
        stateTitle = 'INHALING';
        stateIcon = Icons.arrow_upward;
        break;
      case 'EXHALING':
        activeAccentColor = const Color(0xFFD946EF);
        stateTitle = 'EXHALING';
        stateIcon = Icons.arrow_downward;
        break;
      case 'HOLDING':
      default:
        activeAccentColor = const Color(0xFF3B82F6);
        stateTitle = _isTracking ? 'CALIBRATING...' : 'READY';
        stateIcon = Icons.hourglass_empty;
        break;
    }

    // Calculate elapsed time in the current breathing phase
    double elapsedPhaseSeconds = 0.0;
    if (_isTracking && _phaseStartTime != null) {
      elapsedPhaseSeconds = DateTime.now().difference(_phaseStartTime!).inMilliseconds / 1000.0;
    }

    // Format timer
    int minutes = _sessionSeconds ~/ 60;
    int seconds = _sessionSeconds % 60;
    String timerText = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    // Map detrended values dynamically to scale for the animated circle
    double maxVal = _recentDetrendedBuffer.isNotEmpty ? _recentDetrendedBuffer.reduce(math.max) : 0.2;
    double minVal = _recentDetrendedBuffer.isNotEmpty ? _recentDetrendedBuffer.reduce(math.min) : -0.2;
    double range = maxVal - minVal;
    if (range < 0.1) range = 0.1; // Floor range to avoid division by zero or over-scaling noise

    double currentVal = _chartBuffer.isNotEmpty ? _chartBuffer.last : 0.0;
    // Map current value to range of 0.0 (full contraction) to 1.0 (full expansion)
    double scaleFraction = (currentVal - minVal) / range;
    scaleFraction = scaleFraction.clamp(0.0, 1.0);
    double circleScale = 1.0 + (scaleFraction * 0.5); // Scales circle from 1.0x to 1.5x

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: activeAccentColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.spa, color: activeAccentColor, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BreathTrack',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                Text(
                  'Abdominal Biofeedback',
                  style: TextStyle(fontSize: 10, color: Colors.white54),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings, color: Colors.white70),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              
              // Instructions text at the top
              if (!_isTracking)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151F32).withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.03)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.white.withOpacity(0.5), size: 16),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Lay flat on your back, place your phone on your stomach (any direction), and press Start.',
                          style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              
              const SizedBox(height: 16),

              // 2x2 Grid of metrics
              GridView.count(
                shrinkWrap: true,
                crossAxisCount: 2,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.6,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildMetricCard(
                    'BREATHING STATE',
                    stateTitle,
                    stateIcon,
                    activeAccentColor,
                    textColor: activeAccentColor,
                    pulse: _isTracking && _currentPhase != 'HOLDING',
                  ),
                  _buildMetricCard(
                    'BREATHS / MIN',
                    _isTracking && _bpm > 0 ? _bpm.toStringAsFixed(1) : '--',
                    Icons.favorite,
                    const Color(0xFF10B981),
                    subtitle: _isTracking && _bpm > 0
                        ? (_bpm < 10 ? 'Relaxed / Deep' : 'Normal')
                        : 'Waiting...',
                  ),
                  _buildMetricCard(
                    'LAST INHALE',
                    _isTracking && _lastInhaleSec > 0 ? '${_lastInhaleSec.toStringAsFixed(1)}s' : '--',
                    Icons.arrow_upward,
                    const Color(0xFF00F2FE),
                  ),
                  _buildMetricCard(
                    'LAST EXHALE',
                    _isTracking && _lastExhaleSec > 0 ? '${_lastExhaleSec.toStringAsFixed(1)}s' : '--',
                    Icons.arrow_downward,
                    const Color(0xFFD946EF),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Interactive breathing circle display
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 260,
                    height: 260,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Pacer Circle (Visual Breathing Guide)
                        if (_pacerEnabled)
                          AnimatedBuilder(
                            animation: _pacerController,
                            builder: (context, child) {
                              double t = _pacerController.value;
                              double totalCycleSec = _pacerInhaleSec + _pacerExhaleSec;
                              double r = _pacerInhaleSec / totalCycleSec;
                              double pacerScale;
                              
                              if (t < r) {
                                // Inhale phase: expand
                                double p = t / r;
                                pacerScale = 1.0 + (p * 0.7);
                              } else {
                                // Exhale phase: contract
                                double p = (t - r) / (1.0 - r);
                                pacerScale = 1.7 - (p * 0.7);
                              }
                              
                              return Container(
                                width: 150 * pacerScale,
                                height: 150 * pacerScale,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF3B82F6).withOpacity(0.35),
                                    width: 2.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF3B82F6).withOpacity(0.05),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),

                        // Active Stomach Tracker Circle
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          width: 120 * circleScale,
                          height: 120 * circleScale,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                activeAccentColor,
                                activeAccentColor.withOpacity(0.7),
                                activeAccentColor.withOpacity(0.1),
                              ],
                              stops: const [0.0, 0.6, 1.0],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: activeAccentColor.withOpacity(0.25),
                                blurRadius: 20 * circleScale,
                                spreadRadius: 4 * circleScale,
                              ),
                            ],
                          ),
                          child: Center(
                            child: !_isTracking
                                ? Icon(
                                    Icons.play_arrow_outlined,
                                    size: 40,
                                    color: Colors.white.withOpacity(0.8),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          _currentPhase == 'HOLDING' ? 'CALIBRATE' : _currentPhase,
                                          style: TextStyle(
                                            fontSize: 9 * circleScale,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.5,
                                            color: Colors.white.withOpacity(0.85),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          "${elapsedPhaseSeconds.toStringAsFixed(1)}s",
                                          style: TextStyle(
                                            fontSize: 16 * circleScale,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                        if (_pacerEnabled) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            _currentPhase == 'INHALING'
                                                ? "Target: ${_pacerInhaleSec.round()}s"
                                                : (_currentPhase == 'EXHALING'
                                                    ? "Target: ${_pacerExhaleSec.round()}s"
                                                    : ""),
                                            style: TextStyle(
                                              fontSize: 7.5 * circleScale,
                                              color: Colors.white.withOpacity(0.5),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                          ),
                        ),

                        // Dynamic Halo
                        Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withOpacity(0.02),
                              width: 1.0,
                            ),
                          ),
                        ),
                        
                        // Active Axis Marker (Auto selection indicator)
                        Positioned(
                          bottom: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.05)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isTracking ? Colors.green : Colors.grey,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Tracking Axis: $_activeAxis${_axisOverride == 'Auto' ? ' (Auto)' : ''}',
                                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Live Chart Area
              Container(
                height: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFF121B2E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                ),
                padding: const EdgeInsets.only(top: 16, bottom: 8, left: 16, right: 16),
                child: Stack(
                  children: [
                    // Grid & Line Wave
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: CustomPaint(
                          painter: BreathingChartPainter(
                            data: _chartBuffer,
                            maxPoints: _maxChartPoints,
                            activeColor: activeAccentColor,
                            isTracking: _isTracking,
                          ),
                        ),
                      ),
                    ),
                    
                    // Session Timer overlay on chart
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Row(
                        children: [
                          Icon(Icons.timer, size: 14, color: _isTracking ? const Color(0xFF3B82F6) : Colors.white24),
                          const SizedBox(width: 4),
                          Text(
                            timerText,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _isTracking ? Colors.white : Colors.white24,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Guide overlay when not tracking
                    if (!_isTracking)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B0F19).withOpacity(0.85),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withOpacity(0.05)),
                          ),
                          child: const Text(
                            'Session Inactive\nPress Start below to begin recording',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.4),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Start / Stop controller button
              Padding(
                padding: const EdgeInsets.only(bottom: 24.0),
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isTracking ? _stopTracking : _startTracking,
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: EdgeInsets.zero,
                      elevation: 8,
                      shadowColor: _isTracking
                          ? const Color(0xFFF43F5E).withOpacity(0.3)
                          : const Color(0xFF00F2FE).withOpacity(0.3),
                    ),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: _isTracking
                              ? [const Color(0xFFF43F5E), const Color(0xFFBE123C)] // Crimson Gradient
                              : [const Color(0xFF00F2FE), const Color(0xFF4FACFE)], // Cyan Gradient
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Container(
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _isTracking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                              color: _isTracking ? Colors.white : Colors.black,
                              size: 28,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isTracking ? 'STOP SESSION' : 'START TRACKING',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                                color: _isTracking ? Colors.white : Colors.black,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard(
    String title,
    String value,
    IconData icon,
    Color themeColor, {
    Color? textColor,
    String? subtitle,
    bool pulse = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF151F32),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: pulse ? themeColor.withOpacity(0.3) : Colors.white.withOpacity(0.04),
          width: pulse ? 1.5 : 1.0,
        ),
        boxShadow: pulse
            ? [
                BoxShadow(
                  color: themeColor.withOpacity(0.05),
                  blurRadius: 8,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: Colors.white54,
                ),
              ),
              Icon(icon, size: 14, color: themeColor),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: textColor ?? Colors.white,
            ),
          ),
          Text(
            subtitle ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 9,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );
  }
}

/// CustomPainter to render the live rolling breathing wave graph with grid and gradient fills.
class BreathingChartPainter extends CustomPainter {
  final List<double> data;
  final int maxPoints;
  final Color activeColor;
  final bool isTracking;

  BreathingChartPainter({
    required this.data,
    required this.maxPoints,
    required this.activeColor,
    required this.isTracking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double width = size.width;
    final double height = size.height;
    final double centerY = height / 2.0;

    // Draw grid background
    final Paint gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..strokeWidth = 1.0;

    // Horizontal grid lines
    const int gridRows = 4;
    for (int i = 1; i < gridRows; i++) {
      double y = height * (i / gridRows);
      canvas.drawLine(Offset(0, y), Offset(width, y), gridPaint);
    }

    // Vertical grid lines
    const int gridCols = 8;
    for (int i = 1; i < gridCols; i++) {
      double x = width * (i / gridCols);
      canvas.drawLine(Offset(x, 0), Offset(x, height), gridPaint);
    }

    // Center Baseline (detrended 0 level)
    final Paint baselinePaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, centerY), Offset(width, centerY), baselinePaint);

    if (data.isEmpty || !isTracking) return;

    // Determine scale limits dynamically to avoid flat signals looking huge
    double maxVal = data.reduce(math.max);
    double minVal = data.reduce(math.min);
    double absMax = math.max(maxVal.abs(), minVal.abs());
    
    // We establish a minimum vertical boundary of +/-0.15 m/s2 to prevent noise amplification
    double scaleYLimit = math.max(0.15, absMax * 1.15);

    // X-step between successive coordinates
    double stepX = width / (maxPoints - 1);
    
    // Shift points to align to the right of the chart
    double startX = width - ((data.length - 1) * stepX);

    final Path wavePath = Path();
    final List<Offset> points = [];

    for (int i = 0; i < data.length; i++) {
      double x = startX + (i * stepX);
      // Map detrended values to Y coordinate (-scaleYLimit maps to height, +scaleYLimit maps to 0)
      double val = data[i];
      double y = centerY - (val / scaleYLimit) * (height / 2.0);
      
      // Clamp values within chart frame boundaries
      y = y.clamp(0.0, height);

      if (i == 0) {
        wavePath.moveTo(x, y);
      } else {
        wavePath.lineTo(x, y);
      }
      points.add(Offset(x, y));
    }

    // Draw shaded gradient underneath/above baseline
    final Path fillPath = Path.from(wavePath);
    fillPath.lineTo(points.last.dx, centerY);
    fillPath.lineTo(points.first.dx, centerY);
    fillPath.close();

    final Paint fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          activeColor.withOpacity(0.25),
          activeColor.withOpacity(0.01),
        ],
      ).createShader(Rect.fromLTRB(0, 0, width, height))
      ..style = PaintingStyle.fill;
    
    canvas.drawPath(fillPath, fillPaint);

    // Draw primary line wave
    final Paint linePaint = Paint()
      ..color = activeColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(wavePath, linePaint);

    // Draw a pulsing indicator dot at the latest signal value
    if (points.isNotEmpty) {
      final Offset latestPt = points.last;
      
      final Paint outerGlowPaint = Paint()
        ..color = activeColor.withOpacity(0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(latestPt, 8.0, outerGlowPaint);

      final Paint innerDotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(latestPt, 4.0, innerDotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant BreathingChartPainter oldDelegate) {
    // Repaint on change
    return oldDelegate.data != data || oldDelegate.activeColor != activeColor || oldDelegate.isTracking != isTracking;
  }
}
