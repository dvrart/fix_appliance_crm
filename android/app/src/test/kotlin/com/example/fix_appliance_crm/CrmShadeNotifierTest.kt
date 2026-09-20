package com.example.fix_appliance_crm

import com.twilio.twilio_voice.service.TVConnectionService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CrmShadeNotifierTest {
    @Test
    fun legacyAndFcmPhoneFieldsShareOneCard() {
        val remote = mapOf("type" to "call", "peer" to "+1 (416) 555-0101", "callSid" to "CA-test-1")
        val local = mapOf("type" to "call", "from" to "4165550101", "callSid" to "CA-test-1")
        assertEquals("crm_inbox_4165550101", CrmShadeNotifier.shadeTag(remote))
        assertEquals(CrmShadeNotifier.shadeTag(remote), CrmShadeNotifier.shadeTag(local))
    }

    @Test
    fun oneCallKeepsItsEventWhileNewCallsRemainDistinct() {
        val first = mapOf("type" to "call", "callSid" to "CA-test-1")
        assertEquals("call:CA-test-1", CrmShadeNotifier.eventIdFor(first))
        assertEquals(CrmShadeNotifier.eventIdFor(first), CrmShadeNotifier.eventIdFor(first + ("kind" to "call_offer")))
        assertNotEquals(CrmShadeNotifier.eventIdFor(first), CrmShadeNotifier.eventIdFor(first + ("callSid" to "CA-test-2")))
    }

    @Test
    fun smsAndItsJobUpdateShareTheOriginalEvent() {
        val sms = mapOf("type" to "sms", "messageId" to "SM-test-1")
        val job = sms + mapOf("type" to "job", "source" to "sms", "jobId" to "job-1")
        assertEquals("sms:SM-test-1", CrmShadeNotifier.eventIdFor(sms))
        assertEquals(CrmShadeNotifier.eventIdFor(sms), CrmShadeNotifier.eventIdFor(job))
    }

    @Test
    fun emailDigitsAreNotPhoneDigits() {
        assertEquals("crm_inbox_4165550101@example.test", CrmShadeNotifier.shadeTag(mapOf("type" to "email", "from" to "4165550101@example.test")))
    }

    @Test
    fun longEmailAddressesDoNotCollide() {
        val prefix = "long.customer.address.with.a.shared.prefix"
        val first = CrmShadeNotifier.shadeTag(mapOf("from" to "$prefix@first.example.test"))
        val second = CrmShadeNotifier.shadeTag(mapOf("from" to "$prefix@second.example.test"))
        assertNotEquals(first, second)
        assertTrue(first.length <= 50)
    }

    @Test
    fun unknownNumbersUseTheCallIdAndPreviewTagsAreKept() {
        assertEquals("crm_call_CA-test-unknown", CrmShadeNotifier.shadeTag(mapOf("type" to "call", "from" to "Unknown", "callSid" to "CA-test-unknown")))
        assertEquals("look_preview", CrmShadeNotifier.shadeTag(mapOf("tag" to "look_preview")))
    }

    @Test
    fun backgroundPushCannotStartANewMicrophoneForegroundService() {
        assertFalse(TVConnectionService.canStartMicrophoneForeground(visible = false, alreadyRunning = false))
        assertTrue(TVConnectionService.canStartMicrophoneForeground(visible = true, alreadyRunning = false))
        assertTrue(TVConnectionService.canStartMicrophoneForeground(visible = false, alreadyRunning = true))
    }
}
