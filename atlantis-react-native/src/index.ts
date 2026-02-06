import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-atlantis' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const AtlantisModule = NativeModules.AtlantisReactNative
  ? NativeModules.AtlantisReactNative
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

/**
 * Start Atlantis and begin capturing HTTP/HTTPS traffic.
 *
 * Traffic is sent to the Proxyman macOS app over the local network.
 * On iOS, Atlantis uses NSURLSession method swizzling to capture all traffic automatically.
 * On Android, Atlantis injects an OkHttp interceptor into React Native's networking layer.
 *
 * @param hostName - Optional hostname of the Mac running Proxyman.
 *   If not provided, Atlantis will auto-discover Proxyman on the local network.
 *   Example: 'MacBook-Pro.local'
 */
export function start(hostName?: string): void {
  AtlantisModule.start(hostName ?? null);
}

/**
 * Stop Atlantis and cease capturing traffic.
 *
 * Disconnects from Proxyman and stops all network interception.
 */
export function stop(): void {
  AtlantisModule.stop();
}

/**
 * Check if Atlantis is currently running and capturing traffic.
 *
 * @returns Promise that resolves to true if Atlantis is active.
 */
export function isRunning(): Promise<boolean> {
  return AtlantisModule.isRunning();
}
