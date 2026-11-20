package io.github.utof.eeg_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure parts of the phone's Wi-Fi during a night (WifiFacts.kt, DECISIONS rows 610-619): who holds the process's
 * one Wi-Fi lock across a night's start and Stop, and the words of the night's Wi-Fi line.
 */
class WifiFactsTest {
    @Test
    fun theLockIsHeldWhileAnyEngineAsks() {
        val h = WifiHolders()
        assertTrue(h.set("screen", true))
        // Start night: the recorder takes it, then the screen lets go: held all along
        assertTrue(h.set("recorder", true))
        assertTrue(h.set("screen", false))
        // Stop: the screen serves again before the recorder's server has closed; the recorder letting go late keeps it
        assertTrue(h.set("screen", true))
        assertTrue(h.set("recorder", false))
        assertEquals(listOf("screen"), h.names())
        assertFalse(h.set("screen", false))
        assertEquals(emptyList<String>(), h.names())
    }

    @Test
    fun askingTwiceIsOnceAndLettingGoOfNothingIsHarmless() {
        val h = WifiHolders()
        assertTrue(h.set("recorder", true))
        assertTrue(h.set("recorder", true))
        assertFalse(h.set("recorder", false))
        assertFalse(h.set("recorder", false))
        assertFalse(h.set("screen", false))
    }

    @Test
    fun anEngineThatEndsLetsGoOfItsOwnOnly() {
        val h = WifiHolders()
        h.set("screen", true)
        h.set("recorder", true)
        assertTrue(h.set("recorder", false)) // the recorder's engine destroyed (EegApp.kt)
        assertEquals(listOf("screen"), h.names())
    }

    @Test
    fun theDefaultRouteInWords() {
        assertEquals("none", WifiFacts.route(null))
        assertEquals("wifi", WifiFacts.route(setOf("wifi")))
        assertEquals("cell", WifiFacts.route(setOf("cell")))
        assertEquals("vpn over wifi", WifiFacts.route(setOf("vpn", "wifi")))
        assertEquals("vpn over cell", WifiFacts.route(setOf("vpn", "cell")))
        assertEquals("vpn", WifiFacts.route(setOf("vpn")))
        assertEquals("ethernet", WifiFacts.route(setOf("ethernet")))
        assertEquals("other", WifiFacts.route(setOf("bluetooth")))
        assertEquals("other", WifiFacts.route(emptySet()))
    }

    @Test
    fun onlyRealReadingsAreKept() {
        assertEquals(866, WifiFacts.linkMbps(866))
        assertEquals(null, WifiFacts.linkMbps(-1)) // WifiInfo.LINK_SPEED_UNKNOWN
        assertEquals(-58, WifiFacts.rssi(-58))
        assertEquals(null, WifiFacts.rssi(-127)) // WifiInfo's invalid reading
        assertEquals(null, WifiFacts.rssi(0))
        assertEquals(5180, WifiFacts.freqMhz(5180))
        assertEquals(null, WifiFacts.freqMhz(-1))
    }

    @Test
    fun theOldWifiSleepPolicyIsReadOnlyWhenItIsOneOfItsValues() {
        assertEquals(0, WifiFacts.sleepPolicy(0))
        assertEquals(2, WifiFacts.sleepPolicy(2))
        assertEquals(null, WifiFacts.sleepPolicy(-1)) // not set on this phone
        assertEquals(null, WifiFacts.sleepPolicy(7))
    }
}
