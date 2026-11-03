# ==============================================================================
# JGit (org.eclipse.jgit) on Android
# ==============================================================================
# JGit 5.13 references several JVM-only APIs that do not exist on Android's
# runtime. They belong to optional features that are never exercised on Android
# (GC PID locking via java.lang.management, JMX monitoring via javax.management,
# GSS/Kerberos negotiate auth via org.ietf.jgss). R8 must not hard-fail on
# these missing references; the corresponding code paths are dead on Android
# and will be stripped.
-dontwarn java.lang.management.ManagementFactory
-dontwarn java.lang.management.RuntimeMXBean
-dontwarn javax.management.**
-dontwarn org.ietf.jgss.**

# JGit pulls in slf4j-api but ships no binding; Android logging is used instead.
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn org.slf4j.impl.StaticMDCBinder
-dontwarn org.slf4j.impl.StaticMarkerBinder
