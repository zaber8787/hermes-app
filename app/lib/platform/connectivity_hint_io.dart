import 'connectivity_hint.dart';

/// dart:io devices: no reliable, dependency-free, non-probing connectivity
/// signal exists, so the honest answer is ALWAYS unknown — which never
/// triggers the offline short-circuit (R3 §5.2.1: unknown is not offline).
ConnectivityHint currentConnectivityHint() => ConnectivityHint.unknown;
