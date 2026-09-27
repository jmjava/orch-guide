package com.embabel.guide.rag

import com.embabel.agent.rag.ingestion.ContentFetcher
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException
import java.net.URI

class FallbackContentFetcherTest {

    @Test
    fun `primary failure does not hide a fallback failure`() {
        val uri = URI.create("https://docs.example/page")
        var primaryCalled = false
        var fallbackCalled = false
        val fetcher = FallbackContentFetcher(
            primary = ContentFetcher {
                primaryCalled = true
                throw IOException("primary blocked")
            },
            fallback = ContentFetcher {
                fallbackCalled = true
                throw IOException("fallback blocked")
            },
        )

        val ex = assertThrows(IOException::class.java) { fetcher.fetch(uri) }

        assertEquals("fallback blocked", ex.message)
        assertTrue(primaryCalled)
        assertTrue(fallbackCalled)
    }
}
