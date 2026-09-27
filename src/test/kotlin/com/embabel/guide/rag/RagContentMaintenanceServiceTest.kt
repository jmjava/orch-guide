package com.embabel.guide.rag

import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import org.drivine.manager.PersistenceManager
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verifyNoInteractions

class RagContentMaintenanceServiceTest {

    @Test
    fun `resetGitIngestionRevision refuses when git ingestion is not configured`() {
        val persistenceManager = mock(PersistenceManager::class.java)
        val service = RagContentMaintenanceService(guideProperties(), persistenceManager)

        val result = service.resetGitIngestionRevision("/tmp/some-repo")

        assertEquals(null, result.absolutePath)
        assertFalse(result.removed)
        assertEquals("guide.git-ingestion is not configured", result.message)
        verifyNoInteractions(persistenceManager)
    }

    private fun guideProperties() = GuideProperties(
        reloadContentOnStartup = false,
        defaultPersona = "adaptive",
        projectsPath = ".",
        chunkerConfig = null,
        referencesFile = "references.yml",
        content = ContentConfig(
            versioned = VersionedContentConfig(baseUrl = "https://example.invalid/", versions = emptyList()),
            supplementary = emptyList(),
        ),
        toolPrefix = "",
        directories = emptyList(),
        toolGroups = emptySet(),
    )
}
