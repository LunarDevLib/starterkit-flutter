package dev.lunardev.starterkit.preferences

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class PreferencesHandlerPolicyTest {
    @Test
    fun registrationAndInvalidCallsAreInert() {
        val fixture = Fixture()
        fixture.attach()
        assertEquals(0, fixture.workerCreations)
        fixture.call("unknown", mapOf("key" to "ok"))
        fixture.call("read", null)
        fixture.call("read", mapOf("key" to "ok", "extra" to "x"))
        fixture.call("write", mapOf("key" to "ok", "value" to 1))
        fixture.call("read", mapOf("key" to 0))
        assertEquals(0, fixture.workerCreations)
        assertEquals(0, fixture.storageCreations)
        assertEquals(
            listOf("preference.invalid_arguments", "preference.invalid_arguments", "preference.invalid_arguments",
                "preference.invalid_value", "preference.invalid_key"),
            fixture.results.map { it.error },
        )
    }

    @Test
    fun validationEnforcesAsciiSensitivityAndUtf8Bounds() {
        assertNull(PreferencesValidation.key(""))
        assertEquals("a".repeat(128), PreferencesValidation.key("a".repeat(128)))
        assertNull(PreferencesValidation.key("a".repeat(129)))
        assertNull(PreferencesValidation.key("café"))
        listOf("my_access_key", "PASSWORD", "refresh-token", "authz", "api.key").forEach {
            assertNull(PreferencesValidation.key(it))
        }
        assertEquals("é".repeat(2048), PreferencesValidation.value("é".repeat(2048)))
        assertNull(PreferencesValidation.value("é".repeat(2049)))
        assertNull(PreferencesValidation.value("bad\u0000value"))
    }

    @Test
    fun validOperationOpensStorageOnlyWhenQueuedWorkExecutes() {
        val fixture = Fixture()
        fixture.attach()
        fixture.call("write", mapOf("key" to "profile.name", "value" to "Ada"))
        assertEquals(1, fixture.workerCreations)
        assertEquals(0, fixture.storageCreations)
        fixture.worker.runNext()
        assertEquals(1, fixture.storageCreations)
        // This is the fixture label only; the production fixed filename is verified statically.
        assertEquals("starterkit_preferences_v1", fixture.storeName)
        assertEquals(listOf("write:profile.name:Ada"), fixture.store.events)
        assertNull(fixture.results.single().error)
    }

    @Test
    fun writesAndRemovalsRequireSuccessfulCommitAndRedactFailures() {
        val fixture = Fixture()
        fixture.attach()
        fixture.store.writeResult = false
        fixture.call("write", mapOf("key" to "k", "value" to "v"))
        fixture.worker.runNext()
        assertEquals("preference.operation_failed", fixture.results.last().error)

        fixture.store.removeResult = false
        fixture.call("remove", mapOf("key" to "k"))
        fixture.worker.runNext()
        assertEquals("preference.operation_failed", fixture.results.last().error)

        fixture.store.readValue = object { override fun toString() = "secret-fragment" }
        fixture.call("read", mapOf("key" to "k"))
        fixture.worker.runNext()
        assertEquals("preference.operation_failed", fixture.results.last().error)

        fixture.store.readFailure = IllegalStateException("secret-fragment")
        fixture.call("read", mapOf("key" to "k"))
        fixture.worker.runNext()
        assertEquals("preference.operation_failed", fixture.results.last().error)
        assertFalse(fixture.results.last().error!!.contains("secret-fragment"))

        fixture.store.readFailure = null
        listOf("bad\u0000value", "é".repeat(2049)).forEach { invalidStoredValue ->
            fixture.store.readValue = invalidStoredValue
            fixture.call("read", mapOf("key" to "k"))
            fixture.worker.runNext()
            assertEquals("preference.operation_failed", fixture.results.last().error)
        }
        fixture.store.readValue = "é".repeat(2048)
        fixture.call("read", mapOf("key" to "k"))
        fixture.worker.runNext()
        assertNull(fixture.results.last().error)
        assertEquals("é".repeat(2048), fixture.results.last().value)
    }

    @Test
    fun bootstrapFailureCompletesOnceAndRemovesPendingRequest() {
        val completions = mutableListOf<Pair<Any?, String?>>()
        val policy = PreferencesHandlerPolicy { it() }
        policy.attach({ error("storage must not open") }, { throw IllegalStateException("private") })
        policy.onMethodCall("read", mapOf("key" to "k")) { value, error -> completions += value to error }
        assertEquals(listOf(null to "preference.unavailable"), completions)
        policy.detach()
        assertEquals(1, completions.size)
    }

    @Test
    fun schedulingFailureClosesWorkerAndResolvesAcceptedCall() {
        verifyFailedSecondPost(throws = false)
        verifyFailedSecondPost(throws = true)
    }

    private fun verifyFailedSecondPost(throws: Boolean) {
        val worker = RecordingWorker()
        val completions = mutableListOf<String?>()
        val policy = PreferencesHandlerPolicy { it() }
        policy.attach({ error("storage must not open") }, { worker })
        policy.onMethodCall("read", mapOf("key" to "k")) { _, error -> completions += error }
        val queued = worker.takeNext()
        worker.failNextPost = true
        worker.throwOnFailure = throws
        policy.onMethodCall("read", mapOf("key" to "second")) { _, error -> completions += error }
        assertEquals(listOf("preference.unavailable", "preference.unavailable"), completions)
        assertTrue(worker.cleared)
        assertTrue(worker.quit)
        policy.detach()
        policy.attach({ error("storage must not open") }, { RecordingWorker() })
        queued()
        assertEquals(2, completions.size)
    }

    @Test
    fun detachCancelsQueuedWorkAndCompletesEveryAcceptedCallOnce() {
        val fixture = Fixture()
        fixture.attach()
        fixture.call("read", mapOf("key" to "one"))
        fixture.call("remove", mapOf("key" to "two"))
        fixture.policy.detach()
        assertEquals(2, fixture.results.size)
        assertTrue(fixture.results.all { it.error == "preference.unavailable" })
        assertEquals(0, fixture.storageCreations)
        assertTrue(fixture.worker.cleared)
        assertTrue(fixture.worker.quit)
        fixture.worker.runAll()
        assertEquals(2, fixture.results.size)
    }

    @Test
    fun staleQueuedGenerationCannotOpenStorageAfterReattach() {
        val fixture = Fixture()
        fixture.attach()
        fixture.call("read", mapOf("key" to "old"))
        val staleQueued = fixture.worker.takeNext()
        fixture.policy.detach()
        fixture.attach()
        staleQueued()
        assertEquals(0, fixture.storageCreations)
        assertEquals(1, fixture.results.size)
        fixture.call("read", mapOf("key" to "new"))
        fixture.worker.runNext()
        assertEquals(1, fixture.storageCreations)
    }

    @Test
    fun detachBeforeStorageAcquisitionPreventsOpening() {
        val fixture = Fixture()
        fixture.attach()
        fixture.call("read", mapOf("key" to "k"))
        val queued = fixture.worker.takeNext()
        val entered = CountDownLatch(1)
        val continueToHandler = CountDownLatch(1)
        val thread = Thread {
            entered.countDown()
            if (continueToHandler.await(2, TimeUnit.SECONDS)) queued()
        }.apply { isDaemon = true }
        thread.start()
        assertTrue("worker did not reach pre-handler barrier", entered.await(2, TimeUnit.SECONDS))
        fixture.policy.detach()
        continueToHandler.countDown()
        thread.join(2_000)
        assertFalse("worker did not terminate", thread.isAlive)
        assertEquals(0, fixture.storageCreations)
        assertEquals(1, fixture.results.size)
        assertEquals("preference.unavailable", fixture.results.single().error)
    }

    @Test
    fun detachDuringExecutionDoesNotCompleteTwiceOrClaimRollback() {
        val fixture = Fixture()
        fixture.attach()
        fixture.store.afterWrite = { fixture.policy.detach() }
        fixture.call("write", mapOf("key" to "k", "value" to "v"))
        fixture.worker.runNext()
        assertEquals(1, fixture.results.size)
        assertEquals("preference.unavailable", fixture.results.single().error)
        assertEquals(listOf("write:k:v"), fixture.store.events)
    }

    private class Fixture {
        val store = RecordingStorage()
        val worker = RecordingWorker()
        val results = mutableListOf<Result>()
        var workerCreations = 0
        var storageCreations = 0
        var storeName: String? = null
        val policy = PreferencesHandlerPolicy { it() }

        fun attach() = policy.attach(
            storageFactory = { storageCreations++; storeName = "starterkit_preferences_v1"; store },
            workerFactory = { workerCreations++; worker },
        )

        fun call(method: String, args: Any?) {
            policy.onMethodCall(method, args) { value, error -> results += Result(value, error) }
        }
    }

    private data class Result(val value: Any?, val error: String?)

    private class RecordingWorker : PreferencesWorker {
        val tasks = ArrayDeque<() -> Unit>()
        var cleared = false
        var quit = false
        var failNextPost = false
        var throwOnFailure = false
        override fun post(task: () -> Unit): Boolean {
            if (failNextPost) {
                failNextPost = false
                if (throwOnFailure) throw IllegalStateException("private")
                return false
            }
            tasks.addLast(task)
            return true
        }
        override fun clear() { cleared = true; tasks.clear() }
        override fun quit() { quit = true }
        fun takeNext(): () -> Unit = tasks.removeFirst()
        fun runNext() = tasks.removeFirst().invoke()
        fun runAll() { while (tasks.isNotEmpty()) runNext() }
    }

    private class RecordingStorage : PreferencesStorage {
        val events = mutableListOf<String>()
        var writeResult = true
        var removeResult = true
        var readValue: Any? = null
        var readFailure: RuntimeException? = null
        var afterWrite: (() -> Unit)? = null
        override fun read(key: String): Any? {
            events += "read:$key"
            readFailure?.let { throw it }
            return readValue
        }
        override fun write(key: String, value: String): Boolean {
            events += "write:$key:$value"
            afterWrite?.invoke()
            return writeResult
        }
        override fun remove(key: String): Boolean {
            events += "remove:$key"
            return removeResult
        }
    }
}
