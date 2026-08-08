package com.embabel.guide.spdd

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController

/**
 * Operator API for the DICE persist/retrieve contract (SPIKE-001 leg 3).
 *
 * Write: [load] — structured markdown + lessons.jsonl → `__Entity__` (merge-by-id).
 * Read: [stats], [workSubgraph], [getLesson], [byLabel] — domain retrieval by join keys.
 * MCP: [SpddDomainTools] exported as `spdd_*` when projection is enabled.
 */
@RestController
@RequestMapping("/api/v1/data/spdd-projection")
@ConditionalOnProperty(prefix = "guide.spdd-projection", name = ["enabled"], havingValue = "true")
class SpddProjectionController(
    private val projectionService: SpddMarkdownProjectionService,
) {

    @PostMapping("/load")
    fun load(@RequestBody(required = false) body: LoadRequest?): ResponseEntity<SpddProjectionResult> =
        ResponseEntity.ok(projectionService.load(body?.rootPath))

    @GetMapping("/stats")
    fun stats(): ResponseEntity<StatsResponse> =
        ResponseEntity.ok(
            StatsResponse(
                workIdCount = projectionService.entityCountByLabel("WorkId"),
                canvasCount = projectionService.entityCountByLabel("Canvas"),
                areaCount = projectionService.entityCountByLabel("Area"),
                decisionCount = projectionService.entityCountByLabel("Decision"),
                pitfallCount = projectionService.entityCountByLabel("Pitfall"),
                patternCount = projectionService.entityCountByLabel("Pattern"),
                sessionCount = projectionService.entityCountByLabel("Session"),
                analysisCount = projectionService.entityCountByLabel("Analysis"),
                entityLabel = com.embabel.agent.rag.model.NamedEntityData.ENTITY_LABEL,
            ),
        )

    @GetMapping("/work/{workId}")
    fun workSubgraph(@PathVariable workId: String): ResponseEntity<SpddWorkIdSubgraph> {
        val subgraph = projectionService.subgraphForWorkId(workId.trim())
        return if (subgraph.found) ResponseEntity.ok(subgraph) else ResponseEntity.notFound().build()
    }

    @GetMapping("/area")
    fun areaLessons(@RequestParam name: String): ResponseEntity<SpddAreaLessons> {
        val lessons = projectionService.lessonsForArea(name)
        return if (lessons.found) ResponseEntity.ok(lessons) else ResponseEntity.notFound().build()
    }

    @GetMapping("/lesson/{*id}")
    fun getLesson(@PathVariable id: String): ResponseEntity<SpddLessonDetail> {
        val lesson = projectionService.getLesson(id.removePrefix("/"))
        return if (lesson != null) ResponseEntity.ok(lesson) else ResponseEntity.notFound().build()
    }

    @GetMapping("/by-label")
    fun byLabel(
        @RequestParam label: String,
        @RequestParam(defaultValue = "${SpddMarkdownProjectionService.DEFAULT_LIST_RESULTS}") limit: Int,
    ): ResponseEntity<SpddLabelListResponse> {
        val items = projectionService.listByLabel(label, limit)
        return ResponseEntity.ok(
            SpddLabelListResponse(
                label = label.trim(),
                count = items.size,
                items = items,
            ),
        )
    }

    @ExceptionHandler(IllegalArgumentException::class)
    fun badRequest(e: IllegalArgumentException): ResponseEntity<ErrorResponse> =
        ResponseEntity.badRequest().body(ErrorResponse(e.message ?: "Invalid request"))

    @ExceptionHandler(IllegalStateException::class)
    fun conflict(e: IllegalStateException): ResponseEntity<ErrorResponse> =
        ResponseEntity.status(HttpStatus.CONFLICT).body(ErrorResponse(e.message ?: "Invalid state"))

    data class LoadRequest(val rootPath: String? = null)

    data class StatsResponse(
        val workIdCount: Int,
        val canvasCount: Int,
        val areaCount: Int,
        val decisionCount: Int = 0,
        val pitfallCount: Int = 0,
        val patternCount: Int = 0,
        val sessionCount: Int = 0,
        val analysisCount: Int = 0,
        val entityLabel: String,
    )

    data class ErrorResponse(val error: String)
}
