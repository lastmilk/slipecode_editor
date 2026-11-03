package com.slipe.editor

import android.util.Log
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import java.io.File
import java.util.concurrent.Executors

/// 本地 Git 仓库拉取（Android 使用 JGit）
///
/// 首次 clone，已存在 `.git` 时执行 pull（仅支持 fast-forward 等常规场景）。
object GitClient {
    private const val TAG = "SlipeGit"
    private val executor = Executors.newSingleThreadExecutor()

    fun cloneOrPull(
        url: String,
        destPath: String,
        branch: String,
        username: String,
        token: String,
        callback: (Map<String, Any>?, String?) -> Unit
    ) {
        executor.execute {
            try {
                val dir = File(destPath)
                val credentials = UsernamePasswordCredentialsProvider(
                    username.ifBlank { "oauth2" },
                    token
                )
                val cloned: Boolean
                if (File(dir, ".git").exists()) {
                    Git.open(dir).use { git ->
                        git.pull()
                            .setRemote("origin")
                            .setRemoteBranchName(branch)
                            .setCredentialsProvider(credentials)
                            .call()
                    }
                    cloned = false
                } else {
                    dir.parentFile?.mkdirs()
                    Git.cloneRepository()
                        .setURI(url)
                        .setDirectory(dir)
                        .setBranchesToClone(listOf("refs/heads/$branch"))
                        .setBranch("refs/heads/$branch")
                        .setCredentialsProvider(credentials)
                        .call()
                        .close()
                    cloned = true
                }
                callback(
                    mapOf("path" to dir.absolutePath, "cloned" to cloned),
                    null
                )
            } catch (e: Exception) {
                Log.e(TAG, "cloneOrPull failed: $url", e)
                callback(null, e.message ?: e.javaClass.simpleName)
            }
        }
    }
}
