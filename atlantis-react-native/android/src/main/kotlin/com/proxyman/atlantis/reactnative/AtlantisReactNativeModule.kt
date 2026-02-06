package com.proxyman.atlantis.reactnative

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.modules.network.OkHttpClientProvider
import com.proxyman.atlantis.Atlantis

/**
 * React Native native module that bridges to the Atlantis Android library.
 *
 * Exposes start(), stop(), and isRunning() to JavaScript.
 * On start(), it registers an OkHttpClientFactory that injects the
 * AtlantisInterceptor into React Native's networking layer.
 */
class AtlantisReactNativeModule(
    private val reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = "AtlantisReactNative"

    /**
     * Start Atlantis and begin capturing HTTP/HTTPS traffic.
     *
     * This will:
     * 1. Register the AtlantisInterceptor with React Native's OkHttpClient
     * 2. Start Atlantis NSD discovery (real device) or direct connection (emulator)
     * 3. Begin forwarding captured traffic to Proxyman
     *
     * @param hostName Optional hostname to connect to a specific Proxyman instance
     */
    @ReactMethod
    fun start(hostName: String?) {
        // Inject AtlantisInterceptor into React Native's OkHttp client
        OkHttpClientProvider.setOkHttpClientFactory(
            AtlantisOkHttpInterceptorFactory()
        )

        // Start Atlantis with optional hostname filter
        val resolvedHostName = if (hostName.isNullOrEmpty()) null else hostName
        Atlantis.start(reactContext.applicationContext, resolvedHostName)
    }

    /**
     * Stop Atlantis and cease capturing traffic.
     */
    @ReactMethod
    fun stop() {
        Atlantis.stop()
    }

    /**
     * Check if Atlantis is currently running.
     */
    @ReactMethod
    fun isRunning(promise: Promise) {
        promise.resolve(Atlantis.isRunning())
    }
}
