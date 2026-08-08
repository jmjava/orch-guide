package com.embabel.guide.spdd

import com.embabel.agent.rag.service.NamedEntityDataRepository
import com.embabel.agent.rag.service.support.InMemoryNamedEntityDataRepository
import com.embabel.common.ai.model.EmbeddingService
import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.mockito.Mockito
import java.nio.file.Files
import java.nio.file.Path

class SpddMarkdownProjectionServiceTest {

  @TempDir
  lateinit var tempDir: Path

  private val objectMapper = ObjectMapper()

  // ---------------------------------------------------------------- persist

  @Test
  fun `load projects work id canvas and area from fixture`() {
    val fixtureRoot = Path.of("src/test/resources/spdd-fixture").toAbsolutePath()
    val repo = inMemoryRepository()
    val service = service(repo, fixtureRoot.toString())

    val result = service.load()

    assertEquals(fixtureRoot.normalize().toString(), result.rootPath)
    assertTrue(result.workIds >= 1)
    assertTrue(result.canvases >= 1)
    assertTrue(result.areas >= 1)
    assertEquals(0, result.skippedFiles)
    assertTrue(service.entityCountByLabel("WorkId") >= 1)
    assertTrue(repo.findByLabel("Area").any { it.name == "src/billing" })
  }

  @Test
  fun `load is idempotent - reloading does not duplicate entities`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    val repo = inMemoryRepository()
    val service = service(repo, root.toString())

    val first = service.load()
    val countsAfterFirst = repo.findByLabel("WorkId").size + repo.findByLabel("Canvas").size +
      repo.findByLabel("Area").size + repo.findByLabel("Pitfall").size
    val second = service.load()
    val countsAfterSecond = repo.findByLabel("WorkId").size + repo.findByLabel("Canvas").size +
      repo.findByLabel("Area").size + repo.findByLabel("Pitfall").size

    assertEquals(first.workIds, second.workIds)
    assertEquals(countsAfterFirst, countsAfterSecond, "merge-by-id must not duplicate on reload")
  }

  @Test
  fun `load ignores canvas without work id and projects the rest`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    Files.writeString(root.resolve("spdd/canvas/no-work-id.md"), "# Not a canvas at all\n")
    val service = service(inMemoryRepository(), root.toString())

    val result = service.load()

    assertEquals(1, result.workIds, "valid canvas still projected")
    assertEquals(1, result.canvases)
  }

  @Test
  fun `load projects decision pitfall pattern session and analysis from lessons jsonl`() {
    val root = buildProject(
      tempDir.resolve("lessons"),
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"decision:SPIKE-FIX-001-retrieval-fixture:src/billing:adr.md","kind":"decision","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"code","ts":"2026-07-05T13:00:00Z","title":"use idempotency keys","body":"detail about keys","source":"adr.md","schema":1}
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:pitfalls.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"code","ts":"2026-07-05T13:00:00Z","title":"retry storms","body":"avoid unbounded retries","source":"pitfalls.md","schema":1}
        {"id":"pattern:SPIKE-FIX-001-retrieval-fixture:src/billing:patterns.md","kind":"pattern","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"code","ts":"2026-07-05T13:00:00Z","title":"outbox pattern","body":"use transactional outbox","source":"patterns.md","schema":1}
        {"id":"session:SPIKE-FIX-001-retrieval-fixture:src/billing:retro","kind":"session","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"retro","ts":"2026-07-05T14:00:00Z","title":"retro notes","body":"session summary text","source":"retro","schema":1}
        {"id":"analysis:SPIKE-FIX-001-retrieval-fixture:engine:analysis","kind":"analysis","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"engine","phase":"analysis","ts":"2026-07-05T12:00:00Z","title":"domain analysis","body":"requirements breakdown","source":"analysis","schema":1}
      """.trimIndent(),
    )
    val repo = inMemoryRepository()
    val service = service(repo, root.toString())

    val result = service.load()

    assertEquals(1, result.decisions)
    assertEquals(1, result.pitfalls)
    assertEquals(1, result.patterns)
    assertEquals(1, result.sessions)
    assertEquals(1, result.analyses)

    val subgraph = service.subgraphForWorkId("SPIKE-FIX-001-retrieval-fixture")
    assertTrue(subgraph.found)
    assertEquals(listOf("use idempotency keys"), subgraph.decisions.map { it.name })
    assertEquals(listOf("retry storms"), subgraph.pitfalls.map { it.name })
    assertEquals(listOf("outbox pattern"), subgraph.patterns.map { it.name })
    assertEquals(listOf("retro notes"), subgraph.sessions.map { it.name })
    assertEquals(listOf("domain analysis"), subgraph.analyses.map { it.name })
  }

  @Test
  fun `load projects keywords as entity property`() {
    val root = buildProject(
      tempDir.resolve("keywords"),
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"sqlite lock","body":"watch WAL mode","source":"p.md","keywords":["sqlite","wal"],"schema":1}
      """.trimIndent(),
    )
    val service = service(inMemoryRepository(), root.toString())
    service.load()

    val lesson = service.getLesson("pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md")
    assertNotNull(lesson)
    assertEquals(listOf("sqlite", "wal"), lesson!!.keywords)
  }

  @Test
  fun `resolveEffectiveRoot descends into sdlc-spdd home when present`() {
    val parent = tempDir.resolve("workspace")
    val orchestrator = parent.resolve("sdlc-spdd")
    buildProject(
      orchestrator,
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"retry storms","body":"detail","source":"p.md","schema":1}
      """.trimIndent(),
    )
    val service = service(inMemoryRepository(), parent.toString())

    val result = service.load(parent.toString())

    assertEquals(orchestrator.normalize().toString(), result.rootPath)
    assertEquals(1, result.pitfalls)
  }

  // ------------------------------------------------------- root path guard

  @Test
  fun `load rejects root override outside allowed roots`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    val outside = Files.createDirectory(tempDir.resolve("outside"))
    val service = service(inMemoryRepository(), root.toString())

    val e = assertThrows<IllegalArgumentException> { service.load(outside.toString()) }
    assertTrue(e.message!!.contains("not under an allowed root"))
  }

  @Test
  fun `load accepts override under an explicitly allowed root`() {
    val defaultRoot = copyFixtureTo(tempDir.resolve("default"))
    val allowedParent = tempDir.resolve("allowed")
    val otherProject = copyFixtureTo(allowedParent.resolve("other"))
    val service = service(
      inMemoryRepository(),
      defaultRoot.toString(),
      allowedRoots = listOf(allowedParent.toString()),
    )

    val result = service.load(otherProject.toString())

    assertEquals(otherProject.normalize().toString(), result.rootPath)
  }

  @Test
  fun `load accepts override equal to the default root`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    val service = service(inMemoryRepository(), root.toString())

    val result = service.load(root.toString())

    assertEquals(root.normalize().toString(), result.rootPath)
  }

  @Test
  fun `load treats blank override as default root`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    val service = service(inMemoryRepository(), root.toString())

    val result = service.load("   ")

    assertEquals(root.normalize().toString(), result.rootPath)
  }

  @Test
  fun `load rejects missing root directory`() {
    val service = service(inMemoryRepository(), tempDir.resolve("does-not-exist").toString())
    assertThrows<IllegalArgumentException> { service.load() }
  }

  // --------------------------------------------------------------- retrieve

  @Test
  fun `subgraph walk returns canvas and area neighbors`() {
    val root = copyFixtureTo(tempDir.resolve("project"))
    val service = service(inMemoryRepository(), root.toString())
    service.load()

    val subgraph = service.subgraphForWorkId("SPIKE-FIX-001-retrieval-fixture")

    assertTrue(subgraph.found)
    assertTrue(subgraph.canvases.isNotEmpty())
    assertTrue(subgraph.areas.any { it.name == "src/billing" })
    assertTrue(subgraph.pitfalls.any { it.name == "idempotency key" })
  }

  @Test
  fun `subgraph for unknown work id reports not found`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    service.load()

    val subgraph = service.subgraphForWorkId("FEAT-999-nope")

    assertFalse(subgraph.found)
  }

  @Test
  fun `subgraph rejects blank work id`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    assertThrows<IllegalArgumentException> { service.subgraphForWorkId("  ") }
  }

  @Test
  fun `lessonsForArea returns cross-run lessons and touching work ids`() {
    val root = buildProject(
      tempDir.resolve("cross"),
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:pitfalls.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"retry storms","body":"detail","source":"pitfalls.md","schema":1}
        {"id":"decision:FEAT-002-other-work:src/billing:adr.md","kind":"decision","work_id":"FEAT-002-other-work","area":"src/billing","title":"use idempotency keys","body":"detail","source":"adr.md","schema":1}
      """.trimIndent(),
    )
    val service = service(inMemoryRepository(), root.toString())
    service.load()

    val lessons = service.lessonsForArea("src/billing")

    assertTrue(lessons.found)
    assertEquals(listOf("retry storms"), lessons.pitfalls.map { it.name })
    assertEquals(listOf("use idempotency keys"), lessons.decisions.map { it.name })
    assertTrue(lessons.workIds.any { it.id == "SPIKE-FIX-001-retrieval-fixture" })
  }

  @Test
  fun `lessonsForArea for unknown area reports not found`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    service.load()

    assertFalse(service.lessonsForArea("does/not/exist").found)
  }

  @Test
  fun `lessonsForArea rejects blank area`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    assertThrows<IllegalArgumentException> { service.lessonsForArea("") }
  }

  @Test
  fun `getLesson returns full body untruncated`() {
    val longBody = "x".repeat(600)
    val root = buildProject(
      tempDir.resolve("full-body"),
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"short title","body":"$longBody","source":"p.md","schema":1}
      """.trimIndent(),
    )
    val service = service(inMemoryRepository(), root.toString())
    service.load()

    val lesson = service.getLesson("pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md")
    assertNotNull(lesson)
    assertEquals(longBody, lesson!!.body)
    assertTrue(lesson.description.length <= SpddMarkdownProjectionService.MAX_ENTITY_DESCRIPTION + 1)
  }

  @Test
  fun `getLesson returns null for unknown id`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    service.load()
    assertEquals(null, service.getLesson("pitfall:UNKNOWN:area:src"))
  }

  @Test
  fun `listByLabel rejects labels outside the schema`() {
    val service = service(inMemoryRepository(), copyFixtureTo(tempDir.resolve("p")).toString())
    val e = assertThrows<IllegalArgumentException> { service.listByLabel("ContentElement") }
    assertTrue(e.message!!.contains("Known labels"))
  }

  @Test
  fun `listByLabel caps results`() {
    val root = copyFixtureTo(tempDir.resolve("p"))
    val service = service(inMemoryRepository(), root.toString())
    service.load()

    assertEquals(1, service.listByLabel("WorkId", maxResults = 1).size)
    assertTrue(service.listByLabel("WorkId", maxResults = 0).isNotEmpty())
    assertTrue(service.listByLabel("WorkId", maxResults = 999999).size <= SpddMarkdownProjectionService.MAX_LIST_RESULTS)
  }

  @Test
  fun `load deduplicates lessons by id`() {
    val root = buildProject(
      tempDir.resolve("dedupe"),
      canvas = CANVAS,
      lessonsJsonl = """
        {"id":"decision:SPIKE-FIX-001-retrieval-fixture:src/billing:adr.md","kind":"decision","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"first","body":"a","source":"adr.md","schema":1}
        {"id":"decision:SPIKE-FIX-001-retrieval-fixture:src/billing:adr.md","kind":"decision","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"duplicate","body":"b","source":"adr.md","schema":1}
      """.trimIndent(),
    )
    val service = service(inMemoryRepository(), root.toString())
    val result = service.load()
    assertEquals(1, result.decisions)
  }

  // ---------------------------------------------------------------- helpers

  private fun service(
    repo: NamedEntityDataRepository,
    defaultRootPath: String,
    allowedRoots: List<String> = emptyList(),
  ): SpddMarkdownProjectionService =
    SpddMarkdownProjectionService(guideProperties(defaultRootPath, allowedRoots), repo, objectMapper)

  private fun guideProperties(defaultRootPath: String, allowedRoots: List<String> = emptyList()) =
    GuideProperties(
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
      spddProjection = GuideProperties.SpddProjection(
        enabled = true,
        defaultRootPath = defaultRootPath,
        allowedRoots = allowedRoots,
      ),
    )

  private fun copyFixtureTo(target: Path): Path {
    val fixture = Path.of("src/test/resources/spdd-fixture")
    Files.walk(fixture).forEach { source ->
      val dest = target.resolve(fixture.relativize(source))
      if (Files.isDirectory(source)) {
        Files.createDirectories(dest)
      } else {
        Files.createDirectories(dest.parent)
        Files.copy(source, dest)
      }
    }
    return target
  }

  private fun buildProject(root: Path, canvas: String, lessonsJsonl: String): Path {
    Files.createDirectories(root.resolve("spdd/canvas"))
    Files.createDirectories(root.resolve("spdd/memory"))
    Files.writeString(root.resolve("spdd/canvas/SPIKE-FIX-001-retrieval-fixture.md"), canvas)
    Files.writeString(root.resolve("spdd/memory/lessons.jsonl"), lessonsJsonl)
    return root
  }

  private fun inMemoryRepository(): NamedEntityDataRepository {
    val embeddingService = Mockito.mock(EmbeddingService::class.java)
    Mockito.`when`(embeddingService.embed(Mockito.anyString())).thenReturn(floatArrayOf(0.1f, 0.2f, 0.3f))
    return InMemoryNamedEntityDataRepository(
      SpddEntityDictionary.create(),
      embeddingService,
      ObjectMapper(),
    )
  }

  companion object {
    private val CANVAS = """
      # REASONS Canvas: SPIKE-FIX-001-retrieval-fixture - Retrieval experiment fixture

      ## Metadata

      - Work ID: SPIKE-FIX-001-retrieval-fixture
      - Work Type: Spike
      - Status: Complete
    """.trimIndent()
  }
}
