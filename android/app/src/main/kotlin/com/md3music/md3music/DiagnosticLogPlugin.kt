package com.md3music.md3music

import android.os.Build
import android.os.Process
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 导出当前应用进程的 Android 原生日志，供诊断报告收集。 */
class DiagnosticLogPlugin {
    companion object {
        private const val TAG = "DiagnosticLog"
        private const val CHANNEL = "com.md3music.md3music/diagnostic_log"
        private const val MAX_OUTPUT_CHARS = 2 * 1024 * 1024
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "getAndroidLogs") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                Thread {
                    // 环形缓冲优先：零 IO、零权限依赖，任何 ROM/时机都有内容。
                    // logcat 退化为「尽力而为」的补充（Android 10+ READ_LOGS 收紧后
                    // 曾多次整份缺失，导致诊断包无据可查）。
                    val ringText = RingLog.ring.render(maxChars = MAX_OUTPUT_CHARS)
                    val logcatText = runCatching { readLogcat() }.getOrElse { error ->
                        Log.w(TAG, "读取 Android 日志失败", error)
                        ""
                    }
                    val merged = buildString {
                        append("===== 进程内环形日志（cap=")
                        append(NativeLogBuffer.DEFAULT_CAPACITY)
                        append("） =====\n")
                        append(ringText)
                        if (logcatText.isNotEmpty()) {
                            append("\n\n===== logcat（尽力而为） =====\n")
                            append(logcatText)
                        }
                    }
                    result.success(merged)
                }.start()
            }
    }

    private fun readLogcat(): String {
        val command = mutableListOf("logcat", "-d", "-v", "threadtime", "-t", "4000")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            command.add("--pid=${Process.myPid()}")
        }
        val process = ProcessBuilder(command)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        return if (output.length > MAX_OUTPUT_CHARS) {
            "[日志过长，仅保留最后 $MAX_OUTPUT_CHARS 个字符]\n" +
                output.takeLast(MAX_OUTPUT_CHARS)
        } else {
            output
        }
    }
}
