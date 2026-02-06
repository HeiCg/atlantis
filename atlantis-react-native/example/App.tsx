import React, { useState, useCallback } from 'react';
import {
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { start, stop, isRunning } from 'react-native-atlantis';

const BASE_URL = 'https://httpbin.proxyman.app';

type LogEntry = {
  id: number;
  method: string;
  status: string;
  message: string;
};

let logId = 0;

export default function App(): React.JSX.Element {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [atlantisStarted, setAtlantisStarted] = useState(false);

  const addLog = useCallback(
    (method: string, status: string, message: string) => {
      setLogs(prev => [
        { id: ++logId, method, status, message },
        ...prev.slice(0, 49),
      ]);
    },
    [],
  );

  // -- Atlantis Controls --

  const handleStart = useCallback(async () => {
    start();
    setAtlantisStarted(true);
    addLog('ATLANTIS', 'OK', 'Started');
  }, [addLog]);

  const handleStop = useCallback(async () => {
    stop();
    setAtlantisStarted(false);
    addLog('ATLANTIS', 'OK', 'Stopped');
  }, [addLog]);

  const handleCheckRunning = useCallback(async () => {
    const running = await isRunning();
    addLog('ATLANTIS', 'OK', `isRunning: ${running}`);
  }, [addLog]);

  // -- HTTP Requests --

  const doGet = useCallback(async () => {
    try {
      const res = await fetch(
        `${BASE_URL}/get?param1=value1&param2=value2`,
      );
      const body = await res.text();
      addLog('GET', `${res.status}`, body.slice(0, 120));
    } catch (e: any) {
      addLog('GET', 'ERR', e.message);
    }
  }, [addLog]);

  const doPost = useCallback(async () => {
    try {
      const res = await fetch(`${BASE_URL}/post`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Proxyman-Key': 'x-proxyman-value',
        },
        body: JSON.stringify({
          name: 'Atlantis',
          platform: 'React Native',
          version: '1.0.0',
        }),
      });
      const body = await res.text();
      addLog('POST', `${res.status}`, body.slice(0, 120));
    } catch (e: any) {
      addLog('POST', 'ERR', e.message);
    }
  }, [addLog]);

  const doPut = useCallback(async () => {
    try {
      const res = await fetch(`${BASE_URL}/put`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'name=Jane+Doe&email=jane%40example.com&age=28',
      });
      const body = await res.text();
      addLog('PUT', `${res.status}`, body.slice(0, 120));
    } catch (e: any) {
      addLog('PUT', 'ERR', e.message);
    }
  }, [addLog]);

  const doDelete = useCallback(async () => {
    try {
      const res = await fetch(`${BASE_URL}/delete`, {
        method: 'DELETE',
      });
      const body = await res.text();
      addLog('DELETE', `${res.status}`, body.slice(0, 120));
    } catch (e: any) {
      addLog('DELETE', 'ERR', e.message);
    }
  }, [addLog]);

  const doError = useCallback(async () => {
    try {
      const res = await fetch(`${BASE_URL}/status/404`);
      addLog('404', `${res.status}`, 'Expected 404 error response');
    } catch (e: any) {
      addLog('404', 'ERR', e.message);
    }
  }, [addLog]);

  return (
    <SafeAreaView style={styles.container}>
      <Text style={styles.title}>Atlantis React Native Example</Text>

      {/* Atlantis Controls */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Atlantis Controls</Text>
        <View style={styles.buttonRow}>
          <TouchableOpacity
            style={[
              styles.button,
              atlantisStarted ? styles.buttonStop : styles.buttonStart,
            ]}
            onPress={atlantisStarted ? handleStop : handleStart}>
            <Text style={styles.buttonText}>
              {atlantisStarted ? 'Stop' : 'Start'}
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.button, styles.buttonInfo]}
            onPress={handleCheckRunning}>
            <Text style={styles.buttonText}>isRunning?</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* HTTP Requests */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>HTTPS Requests</Text>
        <View style={styles.buttonRow}>
          <TouchableOpacity
            style={[styles.button, styles.buttonGet]}
            onPress={doGet}>
            <Text style={styles.buttonText}>GET</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.button, styles.buttonPost]}
            onPress={doPost}>
            <Text style={styles.buttonText}>POST</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.button, styles.buttonPut]}
            onPress={doPut}>
            <Text style={styles.buttonText}>PUT</Text>
          </TouchableOpacity>
        </View>
        <View style={styles.buttonRow}>
          <TouchableOpacity
            style={[styles.button, styles.buttonDelete]}
            onPress={doDelete}>
            <Text style={styles.buttonText}>DELETE</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.button, styles.buttonError]}
            onPress={doError}>
            <Text style={styles.buttonText}>Error 404</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* Log Output */}
      <View style={styles.logSection}>
        <Text style={styles.sectionTitle}>Response Log</Text>
        <ScrollView style={styles.logScroll}>
          {logs.map(log => (
            <View key={log.id} style={styles.logEntry}>
              <Text style={styles.logMethod}>{log.method}</Text>
              <Text
                style={[
                  styles.logStatus,
                  log.status === 'ERR' ? styles.logError : null,
                ]}>
                {log.status}
              </Text>
              <Text style={styles.logMessage} numberOfLines={2}>
                {log.message}
              </Text>
            </View>
          ))}
          {logs.length === 0 && (
            <Text style={styles.logPlaceholder}>
              Tap Start, then send requests to see them in Proxyman
            </Text>
          )}
        </ScrollView>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f5f5f5',
  },
  title: {
    fontSize: 22,
    fontWeight: '700',
    textAlign: 'center',
    marginTop: 16,
    marginBottom: 8,
    color: '#1a1a1a',
  },
  section: {
    paddingHorizontal: 16,
    marginBottom: 12,
  },
  sectionTitle: {
    fontSize: 14,
    fontWeight: '600',
    color: '#666',
    marginBottom: 8,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  buttonRow: {
    flexDirection: 'row',
    gap: 8,
    marginBottom: 8,
  },
  button: {
    flex: 1,
    paddingVertical: 12,
    borderRadius: 10,
    alignItems: 'center',
  },
  buttonText: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '600',
  },
  buttonStart: { backgroundColor: '#34c759' },
  buttonStop: { backgroundColor: '#ff3b30' },
  buttonInfo: { backgroundColor: '#5856d6' },
  buttonGet: { backgroundColor: '#007aff' },
  buttonPost: { backgroundColor: '#ff9500' },
  buttonPut: { backgroundColor: '#af52de' },
  buttonDelete: { backgroundColor: '#ff3b30' },
  buttonError: { backgroundColor: '#8e8e93' },
  logSection: {
    flex: 1,
    paddingHorizontal: 16,
  },
  logScroll: {
    flex: 1,
    backgroundColor: '#fff',
    borderRadius: 10,
    padding: 12,
  },
  logEntry: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingVertical: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#e0e0e0',
  },
  logMethod: {
    width: 70,
    fontSize: 12,
    fontWeight: '700',
    color: '#007aff',
  },
  logStatus: {
    width: 40,
    fontSize: 12,
    fontWeight: '600',
    color: '#34c759',
  },
  logError: {
    color: '#ff3b30',
  },
  logMessage: {
    flex: 1,
    fontSize: 11,
    color: '#666',
  },
  logPlaceholder: {
    textAlign: 'center',
    color: '#999',
    marginTop: 40,
    fontSize: 14,
  },
});
