class PrintJob {
  final int? id;
  final String station;
  final String printerMac;
  final String payload;
  final String status;
  final String error;
  final int createdAt;

  /// 'ticket' for a station order ticket, 'receipt' for a customer receipt.
  final String kind;

  PrintJob({
    this.id,
    required this.station,
    required this.printerMac,
    required this.payload,
    required this.status,
    this.error = '',
    required this.createdAt,
    this.kind = 'ticket',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'station': station,
        'printer_mac': printerMac,
        'payload': payload,
        'status': status,
        'error': error,
        'created_at': createdAt,
        'kind': kind,
      };

  factory PrintJob.fromMap(Map<String, dynamic> map) => PrintJob(
        id: map['id'] as int?,
        station: map['station'] as String,
        printerMac: map['printer_mac'] as String? ?? '',
        payload: map['payload'] as String,
        status: map['status'] as String,
        error: map['error'] as String? ?? '',
        createdAt: map['created_at'] as int,
        kind: map['kind'] as String? ?? 'ticket',
      );
}
