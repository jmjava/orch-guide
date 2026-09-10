package com.embabel.guide.spdd

import com.embabel.agent.api.annotation.LlmTool
import com.fasterxml.jackson.databind.ObjectMapper

/**
 * MCP / LLM tools for SPIKE-001 leg 3 (DICE domain graph).
 *
 * Complements `docs_*` chunk tools: these return typed `__Entity__` neighbors via
 * relationships (`canvas`, `area`), not embedding similarity.
 *
 * List payloads are capped and descriptions truncated for working-store discipline;
 * use [getLesson] to fetch full bodies on demand.
 */
class SpddDomainTools(
    private val projectionService: SpddMarkdownProjectionService,
    private val objectMapper: ObjectMapper,
) {

    @LlmTool(
        description = "DICE domain retrieve: WorkId subgraph via typed edges (canvas, area, lessons). " +
            "Use for auditable SPDD context by Work ID, not chunk similarity. " +
            "Lists are capped; use getLesson for full lesson bodies.",
    )
    fun workSubgraph(
        @LlmTool.Param(description = "Work ID, e.g. SPIKE-001-guide-rag-context-backend") workId: String,
        @LlmTool.Param(description = "Max items per neighbor list (default 20, max 100)", required = false)
        limit: Int? = null,
    ): String = safeJson {
        truncateSubgraph(projectionService.subgraphForWorkId(workId.trim()), cap(limit))
    }

    @LlmTool(
        description = "DICE domain stats: counts of projected WorkId, Canvas, Area, Decision, Pitfall, " +
            "Pattern, Session, and Analysis entities in Neo4j.",
    )
    fun projectionStats(): String = safeJson {
        mapOf(
            "workIdCount" to projectionService.entityCountByLabel("WorkId"),
            "canvasCount" to projectionService.entityCountByLabel("Canvas"),
            "areaCount" to projectionService.entityCountByLabel("Area"),
            "decisionCount" to projectionService.entityCountByLabel("Decision"),
            "pitfallCount" to projectionService.entityCountByLabel("Pitfall"),
            "patternCount" to projectionService.entityCountByLabel("Pattern"),
            "sessionCount" to projectionService.entityCountByLabel("Session"),
            "analysisCount" to projectionService.entityCountByLabel("Analysis"),
            "entityLabel" to com.embabel.agent.rag.model.NamedEntityData.ENTITY_LABEL,
        )
    }

    @LlmTool(
        description = "DICE domain list: NamedEntity nodes by label. " +
            "Results are capped; use workSubgraph or getLesson for targeted retrieval.",
    )
    fun findByLabel(
        @LlmTool.Param(description = "Entity label, e.g. WorkId or Area") label: String,
        @LlmTool.Param(description = "Max results (default 20, max 100)", required = false)
        limit: Int? = null,
    ): String = safeJson {
        projectionService.listByLabel(label.trim(), cap(limit))
            .map { truncateSummary(it) }
    }

    @LlmTool(
        description = "DICE cross-run lessons by code area: decisions, pitfalls, patterns, sessions, " +
            "and analyses recorded by ANY previous Work ID against this area. " +
            "Lists are capped; use getLesson for full bodies.",
    )
    fun areaLessons(
        @LlmTool.Param(description = "Code area name, e.g. 'scripts/'") area: String,
        @LlmTool.Param(description = "Max items per list (default 20, max 100)", required = false)
        limit: Int? = null,
    ): String = safeJson {
        truncateAreaLessons(projectionService.lessonsForArea(area), cap(limit))
    }

    @LlmTool(
        description = "Fetch one SPDD lesson record by id with full (untruncated) body. " +
            "Use after workSubgraph or areaLessons when a truncated entry needs the full text.",
    )
    fun getLesson(
        @LlmTool.Param(description = "Lesson entity id, e.g. pitfall:FEAT-013-x:engine:retro") id: String,
    ): String = safeJson {
        projectionService.getLesson(id.trim())
            ?: mapOf("found" to false, "id" to id.trim())
    }

    private fun cap(limit: Int?): Int =
        (limit ?: SpddMarkdownProjectionService.TOOL_DEFAULT_LIMIT)
            .coerceIn(1, SpddMarkdownProjectionService.TOOL_MAX_LIMIT)

    private fun truncateSummary(summary: SpddEntitySummary): SpddEntitySummary =
        summary.copy(description = truncateText(summary.description))

    private fun truncateText(text: String): String {
        val max = SpddMarkdownProjectionService.TOOL_TRUNCATE_CHARS
        if (text.length <= max) return text
        return text.take(max) + SpddMarkdownProjectionService.TRUNCATE_MARKER
    }

    private fun truncateSubgraph(subgraph: SpddWorkIdSubgraph, limit: Int): SpddWorkIdSubgraph =
        subgraph.copy(
            work = subgraph.work?.let { truncateSummary(it) },
            canvases = subgraph.canvases.take(limit).map { truncateSummary(it) },
            areas = subgraph.areas.take(limit).map { truncateSummary(it) },
            decisions = subgraph.decisions.take(limit).map { truncateSummary(it) },
            pitfalls = subgraph.pitfalls.take(limit).map { truncateSummary(it) },
            patterns = subgraph.patterns.take(limit).map { truncateSummary(it) },
            sessions = subgraph.sessions.take(limit).map { truncateSummary(it) },
            analyses = subgraph.analyses.take(limit).map { truncateSummary(it) },
        )

    private fun truncateAreaLessons(lessons: SpddAreaLessons, limit: Int): SpddAreaLessons =
        lessons.copy(
            areaEntity = lessons.areaEntity?.let { truncateSummary(it) },
            workIds = lessons.workIds.take(limit).map { truncateSummary(it) },
            decisions = lessons.decisions.take(limit).map { truncateSummary(it) },
            pitfalls = lessons.pitfalls.take(limit).map { truncateSummary(it) },
            patterns = lessons.patterns.take(limit).map { truncateSummary(it) },
            sessions = lessons.sessions.take(limit).map { truncateSummary(it) },
            analyses = lessons.analyses.take(limit).map { truncateSummary(it) },
        )

    private fun safeJson(block: () -> Any?): String =
        runCatching { objectMapper.writeValueAsString(block()) }
            .getOrElse { objectMapper.writeValueAsString(mapOf("error" to (it.message ?: it.javaClass.simpleName))) }
}
