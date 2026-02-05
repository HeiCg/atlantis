package com.proxyman.atlantis

import android.content.Context
import android.util.Log
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Atlantis - Capture HTTP/HTTPS traffic from Android apps and send to Proxyman for debugging
 * 
 * Atlantis is an Android library that captures all HTTP/HTTPS traffic from OkHttp
 * (including Retrofit and Apollo) and sends it to Proxyman macOS app for inspection.
 * 
 * ## Quick Start
 * 
 * 1. Initialize Atlantis in your Application class:
 * ```kotlin
 * class MyApplication : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         if (BuildConfig.DEBUG) {
 *             Atlantis.start(this)
 *         }
 *     }
 * }
 * ```
 * 
 * 2. Add the interceptor to your OkHttpClient:
 * ```kotlin
 * val client = OkHttpClient.Builder()
 *     .addInterceptor(Atlantis.getInterceptor())
 *     .build()
 * ```
 * 
 * ## Features
 * - Automatic OkHttp traffic interception
 * - Works with Retrofit and Apollo
 * - Network Service Discovery to find Proxyman
 * - Direct connection support for emulators
 * 
 * @see <a href="https://proxyman.io">Proxyman</a>
 * @see <a href="https://github.com/nicksantamaria/atlantis">GitHub Repository</a>
 */
object Atlantis {
    
    private const val TAG = "Atlantis"
    
    /**
     * Build version of Atlantis Android
     * Must match Proxyman's expected version for compatibility
     */
    const val BUILD_VERSION = "1.0.0"
    
    // MARK: - Private Properties
    
    private var contextRef: WeakReference<Context>? = null
    private var transporter: Transporter? = null
    private var configuration: Configuration? = null
    private var delegate: WeakReference<AtlantisDelegate>? = null
    
    private val isEnabled = AtomicBoolean(false)
    private val interceptor = AtlantisInterceptor()
    
    // MARK: - Public API
    
    /**
     * Start Atlantis and begin looking for Proxyman app
     * 
     * This will:
     * 1. Initialize the transporter
     * 2. Start NSD discovery (for real devices) or direct connection (for emulators)
     * 3. Begin sending captured traffic to Proxyman
     * 
     * @param context Application context
     * @param hostName Optional hostname to connect to a specific Proxyman instance.
     *                 If null, will connect to any Proxyman found on the network.
     *                 You can find your Mac's hostname in Proxyman -> Certificate menu -> 
     *                 Install Certificate for iOS -> With Atlantis
     */
    @JvmStatic
    @JvmOverloads
    fun start(context: Context, hostName: String? = null) {
        if (isEnabled.getAndSet(true)) {
            Log.d(TAG, "Atlantis is already running")
            return
        }
        
        val appContext = context.applicationContext
        contextRef = WeakReference(appContext)
        
        // Create configuration
        configuration = Configuration.default(appContext, hostName)
        
        // Start transporter
        transporter = Transporter(appContext).also {
            it.start(configuration!!)
        }
        
        printStartupMessage(hostName)
    }
    
    /**
     * Stop Atlantis
     * 
     * This will:
     * 1. Stop NSD discovery
     * 2. Close all connections to Proxyman
     * 3. Clear any pending packages
     */
    @JvmStatic
    fun stop() {
        if (!isEnabled.getAndSet(false)) {
            Log.d(TAG, "Atlantis is not running")
            return
        }
        
        transporter?.stop()
        transporter = null
        configuration = null
        contextRef = null
        
        Log.d(TAG, "Atlantis stopped")
    }
    
    /**
     * Get the OkHttp interceptor to add to your OkHttpClient
     * 
     * Usage:
     * ```kotlin
     * val client = OkHttpClient.Builder()
     *     .addInterceptor(Atlantis.getInterceptor())
     *     .build()
     * ```
     * 
     * Note: The interceptor will only capture traffic when Atlantis is started.
     */
    @JvmStatic
    fun getInterceptor(): AtlantisInterceptor {
        return interceptor
    }
    
    /**
     * Check if Atlantis is currently running
     */
    @JvmStatic
    fun isRunning(): Boolean {
        return isEnabled.get()
    }
    
    /**
     * Set a delegate to receive traffic packages
     * 
     * This allows you to observe captured traffic in your app, 
     * in addition to sending it to Proxyman.
     */
    @JvmStatic
    fun setDelegate(delegate: AtlantisDelegate?) {
        this.delegate = delegate?.let { WeakReference(it) }
    }
    
    /**
     * Set a connection listener to monitor Proxyman connection status
     */
    @JvmStatic
    fun setConnectionListener(listener: Transporter.ConnectionListener?) {
        transporter?.connectionListener = listener
    }
    
    // MARK: - Internal API (used by AtlantisInterceptor)
    
    /**
     * Send a traffic package to Proxyman
     * Called internally by AtlantisInterceptor
     */
    internal fun sendPackage(trafficPackage: TrafficPackage) {
        if (!isEnabled.get()) {
            return
        }
        
        // Notify delegate
        delegate?.get()?.onTrafficCaptured(trafficPackage)
        
        // Build and send message
        val configuration = configuration ?: return
        val message = Message.buildTrafficMessage(configuration.id, trafficPackage)
        
        transporter?.send(message)
    }
    
    // MARK: - Private Methods
    
    private fun printStartupMessage(hostName: String?) {
        Log.i(TAG, "---------------------------------------------------------------------------------")
        Log.i(TAG, "---------- \uD83E\uDDCA Atlantis Android is running (version $BUILD_VERSION)")
        Log.i(TAG, "---------- GitHub: https://github.com/nicksantamaria/atlantis")
        if (hostName != null) {
            Log.i(TAG, "---------- Looking for Proxyman with hostname: $hostName")
        } else {
            Log.i(TAG, "---------- Looking for any Proxyman app on the network...")
        }
        Log.i(TAG, "---------------------------------------------------------------------------------")
    }
}

/**
 * Delegate interface for observing captured traffic
 */
interface AtlantisDelegate {
    /**
     * Called when a new traffic package is captured
     * This is called on a background thread
     */
    fun onTrafficCaptured(trafficPackage: TrafficPackage)
}
