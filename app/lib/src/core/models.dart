class AppUser {
  final int id;
  final String email;
  final String fullName;
  final String? phone;
  final String? avatarUrl;
  final String role;
  final bool isActive;
  final bool hasEnrollment;

  const AppUser({required this.id, required this.email, required this.fullName, this.phone, this.avatarUrl, required this.role, required this.isActive, required this.hasEnrollment});

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as int,
    email: json['email'] as String,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    role: json['role'] as String,
    isActive: json['is_active'] as bool? ?? true,
    hasEnrollment: json['has_enrollment'] as bool? ?? false,
  );
}

class SignaturePointData {
  final double x;
  final double y;
  final double timestampMs;
  final double pressure;
  final double touchArea;
  final String pointerType;
  const SignaturePointData({required this.x, required this.y, required this.timestampMs, required this.pressure, required this.touchArea, required this.pointerType});
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'timestamp_ms': timestampMs, 'pressure': pressure, 'touch_area': touchArea, 'pointer_type': pointerType};
}

class CapturedSignature {
  final List<SignaturePointData> points;
  final double width;
  final double height;
  const CapturedSignature({required this.points, required this.width, required this.height});
  Map<String, dynamic> toJson({int session = 0}) => {
    'points': points.map((e) => e.toJson()).toList(),
    'canvas_width': width,
    'canvas_height': height,
    'sampling_rate': 100.0,
    'session': session,
  };
}

class VerificationResultData {
  final int id;
  final bool genuine;
  final String decision;
  final double probability;
  final double threshold;
  final double cosine;
  final String mode;
  final double quality;
  final String createdAt;
  const VerificationResultData({required this.id, required this.genuine, required this.decision, required this.probability, required this.threshold, required this.cosine, required this.mode, required this.quality, required this.createdAt});
  factory VerificationResultData.fromJson(Map<String, dynamic> json) => VerificationResultData(
    id: json['id'] as int,
    genuine: json['genuine'] as bool,
    decision: json['decision'] as String,
    probability: (json['probability'] as num).toDouble(),
    threshold: (json['threshold'] as num).toDouble(),
    cosine: (json['cosine_similarity'] as num).toDouble(),
    mode: json['mode'] as String,
    quality: (json['quality_score'] as num).toDouble(),
    createdAt: json['created_at'] as String,
  );
}
