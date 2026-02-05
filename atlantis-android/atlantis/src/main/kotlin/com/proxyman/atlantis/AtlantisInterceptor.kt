package com.proxyman.atlantis

import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody
import okhttp3.ResponseBody
import okio.Buffer
import okio.GzipSource
import java.io.IOException
import java.nio.charset.Charset
import java.util.UUID

/**
 * OkHttp Interceptor that captures HTTP/HTTPS traffic and sends it to Proxyman
 * 
 * This interceptor should be added to your OkHttpClient:
 * ```
 * val client = OkHttpClient.Builder()
 *     .addInterceptor(Atlantis.getInterceptor())
 *     .build()
 * ```
 * 
 * Works automatically with Retrofit, Apollo, and any library that uses OkHttp.
 */
class AtlantisInterceptor internal constructor() : Interceptor {
    
    companion object {
        private const val MAX_BODY_SIZE = 52428800L // 50MB
        private val UTF8 = Charset.forName("UTF-8")
    }
    
    @Throws(IOException::class)
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val requestId = UUID.randomUUID().toString()
        val startTime = System.currentTimeMillis() / 1000.0
        
        // Capture request
        val atlantisRequest = captureRequest(request)
        val trafficPackage = TrafficPackage(
            id = requestId,
            startAt = startTime,
            request = atlantisRequest
        )
        
        // Execute the request
        val response: Response
        try {
            response = chain.proceed(request)
        } catch (e: IOException) {
            // Capture error
            trafficPackage.endAt = System.currentTimeMillis() / 1000.0
            trafficPackage.error = CustomError.fromException(e)
            
            // Send to Proxyman
            Atlantis.sendPackage(trafficPackage)
            
            throw e
        }
        
        // Capture response
        val (atlantisResponse, responseBodyData) = captureResponse(response)
        trafficPackage.response = atlantisResponse
        trafficPackage.responseBodyData = responseBodyData
        trafficPackage.endAt = System.currentTimeMillis() / 1000.0
        
        // Send to Proxyman
        Atlantis.sendPackage(trafficPackage)
        
        return response
    }
    
    /**
     * Capture request details
     */
    private fun captureRequest(request: Request): com.proxyman.atlantis.Request {
        val url = request.url.toString()
        val method = request.method
        
        // Capture headers
        val headers = mutableMapOf<String, String>()
        for (i in 0 until request.headers.size) {
            val name = request.headers.name(i)
            val value = request.headers.value(i)
            headers[name] = value
        }
        
        // Capture body
        val body = captureRequestBody(request)
        
        return com.proxyman.atlantis.Request.fromOkHttp(
            url = url,
            method = method,
            headers = headers,
            body = body
        )
    }
    
    /**
     * Capture request body as byte array
     */
    private fun captureRequestBody(request: Request): ByteArray? {
        val requestBody = request.body ?: return null
        
        // Skip if body is too large
        val contentLength = requestBody.contentLength()
        if (contentLength > MAX_BODY_SIZE) {
            return null
        }
        
        return try {
            val buffer = Buffer()
            requestBody.writeTo(buffer)
            
            // Check content encoding
            val contentEncoding = request.header("Content-Encoding")
            if (contentEncoding.equals("gzip", ignoreCase = true)) {
                // Decompress for readability
                val gzipSource = GzipSource(buffer)
                val decompressedBuffer = Buffer()
                decompressedBuffer.writeAll(gzipSource)
                decompressedBuffer.readByteArray()
            } else {
                buffer.readByteArray()
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
    
    /**
     * Capture response details and body
     * Returns a Pair of (Response, Base64EncodedBody)
     */
    private fun captureResponse(response: Response): Pair<com.proxyman.atlantis.Response, String> {
        val statusCode = response.code
        
        // Capture headers
        val headers = mutableMapOf<String, String>()
        for (i in 0 until response.headers.size) {
            val name = response.headers.name(i)
            val value = response.headers.value(i)
            headers[name] = value
        }
        
        val atlantisResponse = com.proxyman.atlantis.Response.fromOkHttp(
            statusCode = statusCode,
            headers = headers
        )
        
        // Capture body
        val bodyData = captureResponseBody(response)
        val bodyBase64 = if (bodyData != null && bodyData.isNotEmpty()) {
            Base64Utils.encode(bodyData)
        } else {
            ""
        }
        
        return Pair(atlantisResponse, bodyBase64)
    }
    
    /**
     * Capture response body without consuming the original response
     * OkHttp allows the body to be consumed only once, so we need to
     * create a new response with the same body.
     */
    private fun captureResponseBody(response: Response): ByteArray? {
        val responseBody = response.body ?: return null
        
        // Skip if body is too large
        val contentLength = responseBody.contentLength()
        if (contentLength > MAX_BODY_SIZE) {
            return "<Body too large>".toByteArray()
        }
        
        return try {
            // Peek the body without consuming it
            val source = responseBody.source()
            source.request(Long.MAX_VALUE) // Buffer the entire body
            var buffer = source.buffer.clone()
            
            // Check if response is gzip compressed
            val contentEncoding = response.header("Content-Encoding")
            if (contentEncoding.equals("gzip", ignoreCase = true)) {
                // Decompress for readability
                val gzipSource = GzipSource(buffer)
                val decompressedBuffer = Buffer()
                decompressedBuffer.writeAll(gzipSource)
                buffer = decompressedBuffer
            }
            
            // Limit body size for safety
            val size = minOf(buffer.size, MAX_BODY_SIZE)
            buffer.readByteArray(size)
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}
