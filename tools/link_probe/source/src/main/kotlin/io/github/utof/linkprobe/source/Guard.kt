package io.github.utof.linkprobe.source

import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import android.util.Log

/**
 * The caller check from the research (two-apps-one-core, section 2): the calling UID, to its package names, to
 * hasSigningCertificate against the one pinned SHA-256. Anything else is refused. Every verdict goes to logcat.
 */
object Guard {
    class Verdict(val ok: Boolean, val uid: Int, val packages: List<String>, val why: String)

    private val pinned: ByteArray = BuildConfig.PINNED_READER_SHA256.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    /** For a provider call or a service transaction: who is calling is the binder's calling uid. */
    @Suppress("DEPRECATION")
    fun checkUid(ctx: Context, uid: Int, via: String): Verdict {
        val packages = ctx.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return check(ctx, uid, packages, via)
    }

    /** For the result activity: the system tells it the package that started it for a result (null when started plainly). */
    fun checkPackage(ctx: Context, pkg: String?, via: String): Verdict {
        if (pkg == null) return log(via, Verdict(false, -1, emptyList(), "not started for a result (no calling package)"))
        val uid = try {
            ctx.packageManager.getPackageUid(pkg, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            -1
        }
        return check(ctx, uid, listOf(pkg), via)
    }

    private fun check(ctx: Context, uid: Int, packages: List<String>, via: String): Verdict {
        val pm = ctx.packageManager
        val v = when {
            uid == Process.myUid() -> Verdict(false, uid, packages, "the caller is this app itself")
            packages.isEmpty() -> Verdict(false, uid, packages, "no package visible for uid $uid")
            else -> {
                val bad = packages.firstOrNull { !pm.hasSigningCertificate(it, pinned, PackageManager.CERT_INPUT_SHA256) }
                when {
                    bad == null -> Verdict(true, uid, packages, "signing certificate is the pinned one")
                    visible(pm, bad) -> Verdict(false, uid, packages, "$bad: signing certificate is not the pinned one")
                    else -> Verdict(false, uid, packages, "$bad: package not visible to the source (queries)")
                }
            }
        }
        return log(via, v)
    }

    private fun visible(pm: PackageManager, pkg: String): Boolean = try {
        pm.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun log(via: String, v: Verdict): Verdict {
        Log.i(
            Outbox.TAG,
            "source guard via=$via uid=${v.uid} pkgs=${v.packages} -> ${if (v.ok) "ALLOW" else "REFUSE"} (${v.why}) srcPid=${Outbox.pid}",
        )
        return v
    }

    fun refusal(v: Verdict) = SecurityException("linkprobe-refused: ${v.why}")
}
