package com.proxyman.atlantis

import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test

class MessageTest {
    
    private val gson = Gson()
    
    @Test
    fun `test MessageType serialization`() {
        assertEquals("\"connection\"", gson.toJson(Message.MessageType.CONNECTION))
        assertEquals("\"traffic\"", gson.toJson(Message.MessageType.TRAFFIC))
        assertEquals("\"websocket\"", gson.toJson(Message.MessageType.WEBSOCKET))
    }
    
    @Test
    fun `test build connection message`() {
        val testPackage = TestSerializable("test content")
        val message = Message.buildConnectionMessage("test-id", testPackage)
        
        val json = message.toData()?.toString(Charsets.UTF_8)
        assertNotNull(json)
        
        assertTrue(json!!.contains("\"messageType\":\"connection\""))
        assertTrue(json.contains("\"id\":\"test-id\""))
        assertTrue(json.contains("\"buildVersion\""))
    }
    
    @Test
    fun `test build traffic message`() {
        val testPackage = TestSerializable("test traffic")
        val message = Message.buildTrafficMessage("traffic-id", testPackage)
        
        val json = message.toData()?.toString(Charsets.UTF_8)
        assertNotNull(json)
        
        assertTrue(json!!.contains("\"messageType\":\"traffic\""))
        assertTrue(json.contains("\"id\":\"traffic-id\""))
    }
    
    @Test
    fun `test build websocket message`() {
        val testPackage = TestSerializable("ws message")
        val message = Message.buildWebSocketMessage("ws-id", testPackage)
        
        val json = message.toData()?.toString(Charsets.UTF_8)
        assertNotNull(json)
        
        assertTrue(json!!.contains("\"messageType\":\"websocket\""))
        assertTrue(json.contains("\"id\":\"ws-id\""))
    }
    
    // Helper test class
    private class TestSerializable(val content: String) : Serializable {
        override fun toData(): ByteArray? {
            return Gson().toJson(this).toByteArray(Charsets.UTF_8)
        }
    }
}
