package com.embabel.guide.fitness

import com.tngtech.archunit.core.domain.JavaClass
import com.tngtech.archunit.core.importer.ClassFileImporter
import com.tngtech.archunit.core.importer.ImportOption
import com.tngtech.archunit.core.importer.Location
import com.tngtech.archunit.lang.ArchCondition
import com.tngtech.archunit.lang.ConditionEvents
import com.tngtech.archunit.lang.SimpleConditionEvent
import com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import javax.tools.ToolProvider

/**
 * Production bytecode must not name github.com/embabel/guide as a push URL
 * or a pull-request target. Git remotes are already refused by
 * scripts/forbid-embabel-upstream.sh; this test covers compiled production code.
 */
class NoEmbabelGuideUpstreamTargetArchTest {

    @Test
    fun productionCodeMustNotReferenceEmbabelGuidePushOrPrTarget() {
        val imported = ClassFileImporter()
            .withImportOption(OnlyProductionClasses())
            .importPackages("com.embabel")
        assertTrue(imported.size > 0, "compiled production classes are required")
        classes()
            .should(notReferenceEmbabelGuidePushOrPrTarget())
            .check(imported)
    }

    @Test
    fun classFileThatNamesThePushUrlFailsTheRule(@TempDir dir: Path) {
        val classDir = compile(dir, "PushTarget", PUSH_HTTPS)
        val imported = ClassFileImporter().importPath(classDir)
        assertTrue(imported.size > 0, "compiled push-url class is required")
        val error = assertThrows(AssertionError::class.java) {
            classes()
                .should(notReferenceEmbabelGuidePushOrPrTarget())
                .check(imported)
        }
        val message = error.message ?: ""
        assertTrue(message.contains(HTTPS_NEEDLE), message)
    }

    @Test
    fun classFileThatNamesThisForkPassesTheRule(@TempDir dir: Path) {
        val classDir = compile(dir, "ForkTarget", FORK_HTTPS)
        val imported = ClassFileImporter().importPath(classDir)
        assertTrue(imported.size > 0, "compiled fork class is required")
        classes()
            .should(notReferenceEmbabelGuidePushOrPrTarget())
            .check(imported)
    }

    @Test
    fun matcherHitsEachPushFormAndIgnoresALongerName() {
        assertEquals(HTTPS_NEEDLE, forbiddenHit(PUSH_HTTPS))
        assertEquals(SCP_NEEDLE, forbiddenHit(PUSH_SCP))
        assertEquals(SSH_NEEDLE, forbiddenHit(PUSH_SSH))
        assertNull(forbiddenHit(FORK_HTTPS))
        assertNull(forbiddenHit(LONGER_NAME))
    }
}

private class OnlyProductionClasses : ImportOption {
    override fun includes(location: Location): Boolean {
        return location.contains("/target/classes/") &&
            !location.contains("test-classes")
    }
}

private fun notReferenceEmbabelGuidePushOrPrTarget(): ArchCondition<JavaClass> {
    return object : ArchCondition<JavaClass>(
        "not reference a push URL or PR target for github.com/embabel/guide",
    ) {
        override fun check(item: JavaClass, events: ConditionEvents) {
            val hit = forbiddenHit(classFileText(item))
            if (hit == null) {
                return
            }
            val message = item.name +
                " references an embabel/guide push URL or PR target (" +
                hit +
                ")"
            events.add(SimpleConditionEvent.violated(item, message))
        }
    }
}

private fun classFileText(item: JavaClass): String {
    return readSource(item) ?: readFromClassLoader(item)
}

private fun readFromClassLoader(item: JavaClass): String {
    val resource = item.name.replace('.', '/') + ".class"
    val stream = item.reflect().classLoader.getResourceAsStream(resource)
    val bytes = stream?.use { it.readBytes() }
    return if (bytes == null) {
        UNREADABLE
    } else {
        String(bytes, StandardCharsets.ISO_8859_1)
    }
}

private fun readSource(item: JavaClass): String? {
    val source = item.source.orElse(null) ?: return null
    return try {
        source.uri.toURL().openStream().use { stream ->
            String(stream.readBytes(), StandardCharsets.ISO_8859_1)
        }
    } catch (ex: IOException) {
        UNREADABLE + (ex.message ?: "")
    }
}

private fun forbiddenHit(text: String): String? {
    var found: String? = null
    if (text.startsWith(UNREADABLE)) {
        found = "unreadable class file"
    }
    for (needle in NEEDLES) {
        if (found == null) {
            found = firstExactNeedle(text, needle)
        }
    }
    return found
}

private fun firstExactNeedle(text: String, needle: String): String? {
    var from = 0
    var found: String? = null
    while (from < text.length && found == null) {
        val at = text.indexOf(needle, from)
        if (at < 0) {
            from = text.length
        } else {
            found = exactAt(text, needle, at)
            from = at + 1
        }
    }
    return found
}

private fun exactAt(text: String, needle: String, at: Int): String? {
    val after = at + needle.length
    val next = if (after < text.length) text[after] else '\u0000'
    val continues = next.isLetterOrDigit() || next == '_' || next == '-'
    return if (continues) null else needle
}

private fun compile(dir: Path, className: String, url: String): Path {
    val sources = Files.createDirectory(dir.resolve("src"))
    val classes = Files.createDirectory(dir.resolve("classes"))
    val source = sources.resolve("$className.java")
    val body = "public class $className { static final String url = \"$url\"; }\n"
    Files.writeString(source, body)
    val compiler = ToolProvider.getSystemJavaCompiler()
    assertTrue(compiler != null, "javac is required")
    val compiled = compiler.run(
        null,
        null,
        null,
        "-d",
        classes.toString(),
        source.toString(),
    )
    assertEquals(0, compiled)
    return classes
}

private const val UNREADABLE = "\u0000unreadable-class-file"
private const val HTTPS_NEEDLE = "github.com/embabel/guide"
private const val SCP_NEEDLE = "github.com:embabel/guide"
private const val SSH_NEEDLE = "git@github.com:embabel/guide"
private const val PUSH_HTTPS = "https://github.com/embabel/guide.git"
private const val PUSH_SCP = "github.com:embabel/guide.git"
private const val PUSH_SSH = "git@github.com:embabel/guide.git"
private const val FORK_HTTPS = "https://github.com/jmjava/orch-guide.git"
private const val LONGER_NAME = "https://github.com/embabel/guide-notes.git"

private val NEEDLES = listOf(SSH_NEEDLE, HTTPS_NEEDLE, SCP_NEEDLE)
