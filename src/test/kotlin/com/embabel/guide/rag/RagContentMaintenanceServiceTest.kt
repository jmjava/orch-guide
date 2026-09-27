package com.embabel.guide.rag

import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import org.drivine.manager.PersistenceManager
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.mockito.Mockito.mock
import org.mockito.Mockito.verifyNoInteractions
import java.nio.file.Files
import java.nio.file.Path

class RagContentMaintenanceServiceTest {

    @TempDir
    lateinit var tempDir: Path

    @Test
    fun `resetGitIngestionRevision refuses when git ingestion is disabled`() {
        val repo = Files.createDirectories(tempDir.resolve("repo"))
        val stateFile = tempDir.resolve("revisions.json")
        val abs = repo.toAbsolutePath().normalize().toString()
        val store = GitIngestionRevisionStore(stateFile)
        store.load()
        store.putRevision(abs, "abc123def")
        store.save()

        val persistenceManager = mock(PersistenceManager::class.java)
        val service = RagContentMaintenanceService(
            guideProperties(
                GuideProperties.GitIngestion(enabled = false, stateFile = stateFile.toString()),
            ),
            persistenceManager,
        )

        val result = service.resetGitIngestionRevision(abs)

        assertEquals(null, result.absolutePath)
        assertFalse(result.removed)
        assertEquals("guide.git-ingestion.enabled is false", result.message)
        val reread = GitIngestionRevisionStore(stateFile)
        reread.load()
        assertEquals("abc123def", reread.getRevision(abs).orElse(null))
        verifyNoInteractions(persistenceManager)
    }

    private fun guideProperties(gitIngestion: GuideProperties.GitIngestion) = GuideProperties(
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
        gitIngestion = gitIngestion,
    )
}
