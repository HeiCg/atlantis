import { NativeModules } from 'react-native';
import { start, stop, isRunning } from '../index';

// Mock the React Native NativeModules
jest.mock('react-native', () => {
  const mockModule = {
    start: jest.fn(),
    stop: jest.fn(),
    isRunning: jest.fn(() => Promise.resolve(true)),
  };

  return {
    NativeModules: {
      AtlantisReactNative: mockModule,
    },
    Platform: {
      select: jest.fn((obj: Record<string, string>) => obj.ios ?? obj.default ?? ''),
    },
  };
});

const mockNative = NativeModules.AtlantisReactNative;

beforeEach(() => {
  jest.clearAllMocks();
});

describe('react-native-atlantis', () => {
  describe('start', () => {
    it('calls native start with null when no hostName provided', () => {
      start();
      expect(mockNative.start).toHaveBeenCalledTimes(1);
      expect(mockNative.start).toHaveBeenCalledWith(null);
    });

    it('calls native start with null when undefined is passed', () => {
      start(undefined);
      expect(mockNative.start).toHaveBeenCalledWith(null);
    });

    it('calls native start with the provided hostName', () => {
      start('MacBook-Pro.local');
      expect(mockNative.start).toHaveBeenCalledTimes(1);
      expect(mockNative.start).toHaveBeenCalledWith('MacBook-Pro.local');
    });

    it('passes empty string as hostName when given', () => {
      // Empty string is passed through; native side handles resolution
      start('');
      expect(mockNative.start).toHaveBeenCalledWith('');
    });
  });

  describe('stop', () => {
    it('calls native stop', () => {
      stop();
      expect(mockNative.stop).toHaveBeenCalledTimes(1);
    });
  });

  describe('isRunning', () => {
    it('returns the native module promise result (true)', async () => {
      (mockNative.isRunning as jest.Mock).mockResolvedValueOnce(true);
      const result = await isRunning();
      expect(result).toBe(true);
      expect(mockNative.isRunning).toHaveBeenCalledTimes(1);
    });

    it('returns the native module promise result (false)', async () => {
      (mockNative.isRunning as jest.Mock).mockResolvedValueOnce(false);
      const result = await isRunning();
      expect(result).toBe(false);
    });

    it('propagates native module rejection', async () => {
      (mockNative.isRunning as jest.Mock).mockRejectedValueOnce(
        new Error('native error'),
      );
      await expect(isRunning()).rejects.toThrow('native error');
    });
  });

  describe('module exports', () => {
    it('exports start function', () => {
      expect(typeof start).toBe('function');
    });

    it('exports stop function', () => {
      expect(typeof stop).toBe('function');
    });

    it('exports isRunning function', () => {
      expect(typeof isRunning).toBe('function');
    });
  });
});

describe('missing native module', () => {
  it('throws a linking error when native module is not available', () => {
    // Re-mock with undefined native module
    jest.resetModules();
    jest.mock('react-native', () => ({
      NativeModules: {
        AtlantisReactNative: undefined,
      },
      Platform: {
        select: jest.fn(
          (obj: Record<string, string>) => obj.ios ?? obj.default ?? '',
        ),
      },
    }));

    const { start: startFresh } = require('../index');
    expect(() => startFresh()).toThrow(
      "doesn't seem to be linked",
    );
  });
});
