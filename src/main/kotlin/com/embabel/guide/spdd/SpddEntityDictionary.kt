package com.embabel.guide.spdd

import com.embabel.agent.core.DataDictionary
import com.embabel.guide.spdd.domain.Analysis
import com.embabel.guide.spdd.domain.Area
import com.embabel.guide.spdd.domain.Canvas
import com.embabel.guide.spdd.domain.Decision
import com.embabel.guide.spdd.domain.Operation
import com.embabel.guide.spdd.domain.Pattern
import com.embabel.guide.spdd.domain.Pitfall
import com.embabel.guide.spdd.domain.Session
import com.embabel.guide.spdd.domain.WorkId

/**
 * SDLC-SPDD domain schema for leg 3 entity projection (SPIKE-001).
 *
 * Registered via Embabel's first-class path: [DataDictionary.fromClasses] over
 * [com.embabel.agent.rag.model.NamedEntity] domain types (not DynamicType).
 */
object SpddEntityDictionary {

    private val domainClasses = arrayOf(
        WorkId::class.java,
        Canvas::class.java,
        Operation::class.java,
        Area::class.java,
        Decision::class.java,
        Pitfall::class.java,
        Pattern::class.java,
        Session::class.java,
        Analysis::class.java,
    )

    /** Labels of the SPDD domain schema; used to validate retrieve-side label parameters. */
    val knownLabels: Set<String> = domainClasses.mapNotNull { it.simpleName }.toSet()

    fun create(): DataDictionary = DataDictionary.fromClasses("sdlc-spdd", *domainClasses)
}
