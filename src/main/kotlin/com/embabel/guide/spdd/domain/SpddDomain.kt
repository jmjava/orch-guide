package com.embabel.guide.spdd.domain

import com.embabel.agent.core.Semantics
import com.embabel.agent.core.With
import com.embabel.agent.rag.model.NamedEntity
import com.fasterxml.jackson.annotation.JsonClassDescription

/**
 * SDLC-SPDD domain types for Guide leg-3 projection.
 *
 * Embabel conventions:
 * - Implement [NamedEntity] (`id` / `name` / `description`)
 * - Neo4j label = class simple name (+ `__Entity__` from the repository layer)
 * - Graph relationship names match property names (`canvas`, `area`, …)
 * - [Semantics] documents natural-language predicates for the same edges
 *
 * Persist path uses [com.embabel.agent.rag.model.SimpleNamedEntityData] with
 * `linkedDomainType` resolved from [com.embabel.guide.spdd.SpddEntityDictionary]
 * so merge-by-id projection stays idempotent while the schema is first-class JVM types.
 */
@JsonClassDescription("A unit of SPDD work (FEAT-, SPIKE-, BUG-, REF-, CHORE-)")
data class WorkId(
    override val id: String,
    override val name: String,
    override val description: String,
    val workType: String = "",
    val status: String = "",
    @field:Semantics([With(key = "predicate", value = "has canvas")])
    val canvas: Canvas? = null,
    @field:Semantics([With(key = "predicate", value = "in area")])
    val area: Area? = null,
) : NamedEntity

@JsonClassDescription("REASONS canvas for a Work ID")
data class Canvas(
    override val id: String,
    override val name: String,
    override val description: String,
    val path: String = "",
    val readiness: String = "",
) : NamedEntity

@JsonClassDescription("Canvas operation (T01, T02, …)")
data class Operation(
    override val id: String,
    override val name: String,
    override val description: String,
    val status: String = "",
    @field:Semantics([With(key = "predicate", value = "in canvas")])
    val canvas: Canvas? = null,
) : NamedEntity

@JsonClassDescription("Code area bucket or package")
data class Area(
    override val id: String,
    override val name: String,
    override val description: String,
) : NamedEntity

@JsonClassDescription("Recorded architecture decision")
data class Decision(
    override val id: String,
    override val name: String,
    override val description: String,
    val sourcePath: String = "",
    @field:Semantics([With(key = "predicate", value = "about")])
    val area: Area? = null,
    @field:Semantics([With(key = "predicate", value = "recorded for")])
    val workId: WorkId? = null,
) : NamedEntity

@JsonClassDescription("Known pitfall")
data class Pitfall(
    override val id: String,
    override val name: String,
    override val description: String,
    val sourcePath: String = "",
    @field:Semantics([With(key = "predicate", value = "about")])
    val area: Area? = null,
    @field:Semantics([With(key = "predicate", value = "recorded for")])
    val workId: WorkId? = null,
) : NamedEntity

@JsonClassDescription("Reusable pattern")
data class Pattern(
    override val id: String,
    override val name: String,
    override val description: String,
    val sourcePath: String = "",
    @field:Semantics([With(key = "predicate", value = "about")])
    val area: Area? = null,
    @field:Semantics([With(key = "predicate", value = "recorded for")])
    val workId: WorkId? = null,
) : NamedEntity

@JsonClassDescription("Session capture (key points from a work session)")
data class Session(
    override val id: String,
    override val name: String,
    override val description: String,
    val sourcePath: String = "",
    @field:Semantics([With(key = "predicate", value = "about")])
    val area: Area? = null,
    @field:Semantics([With(key = "predicate", value = "recorded for")])
    val workId: WorkId? = null,
) : NamedEntity

@JsonClassDescription("Analysis artifact (requirements / domain analysis)")
data class Analysis(
    override val id: String,
    override val name: String,
    override val description: String,
    val sourcePath: String = "",
    @field:Semantics([With(key = "predicate", value = "about")])
    val area: Area? = null,
    @field:Semantics([With(key = "predicate", value = "recorded for")])
    val workId: WorkId? = null,
) : NamedEntity
