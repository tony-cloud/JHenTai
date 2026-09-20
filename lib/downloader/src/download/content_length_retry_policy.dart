/// An archive URL can exist before the server finishes building its ZIP.
class ContentLengthRetryPolicy {
  final int maxAttempts;
  final Duration delay;

  const ContentLengthRetryPolicy({this.maxAttempts = 1, this.delay = Duration.zero})
      : assert(maxAttempts > 0);

  factory ContentLengthRetryPolicy.forArchiveSize(int bytes) {
    // Allow roughly 16 MiB/s of preparation, with a useful minimum for cold
    // archives and a cap to keep polling responsive for very large galleries.
    final int seconds = (bytes / (16 * 1024 * 1024)).ceil().clamp(30, 180);
    return ContentLengthRetryPolicy(maxAttempts: 12, delay: Duration(seconds: seconds));
  }
}
