package com.embabel.guide.rag

import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import org.drivine.manager.PersistenceManager
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verifyNoInteractions

class RagContentMaintenanceServiceTest {

    @Test
    fun `executePurge refuses when uri prefix and directory are blank after trim`() {
        val persistenceManager = mock(PersistenceManager::class.java)
        val service = RagContentMaintenanceService(guideProperties(), persistenceManager)

        val ex = assertThrows(IllegalArgumentException::class.java) {
            service.executePurge("   ", " \t ", true)
        }

        assertEquals("Provide uriPrefix or directory", ex.message)
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
