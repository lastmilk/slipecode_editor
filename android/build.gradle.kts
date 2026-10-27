allprojects {
    repositories {
        // 优先使用国内镜像，避免 Maven Central 限流 (429)
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // Flutter 引擎产物（io.flutter:*）仅在此仓库
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Some Flutter plugins declare a compileSdk older than what their own
// dependencies require: file_picker / permission_handler_android use 34 and
// jni / jni_flutter use 35, while flutter_plugin_android_lifecycle requires 36.
// Force every Android module to compile against API 36 so that the AAR
// metadata check passes. Reflection keeps this working across AGP DSL
// revisions. This must stay above the `evaluationDependsOn(":app")` block,
// otherwise the projects are already evaluated by the time we register.
fun Project.forceCompileSdk(api: Int) {
    val androidExtension = extensions.findByName("android") ?: return
    val methods = androidExtension.javaClass.methods
    for (setterName in listOf("setCompileSdk", "setCompileSdkVersion")) {
        val setter = methods.firstOrNull { m ->
            m.name == setterName &&
                m.parameterTypes.size == 1 &&
                (m.parameterTypes[0] == Int::class.javaPrimitiveType ||
                    m.parameterTypes[0] == Integer::class.java)
        } ?: continue
        runCatching { setter.invoke(androidExtension, api) }
    }
}

subprojects {
    val target = this
    if (target.state.executed) {
        target.forceCompileSdk(36)
    } else {
        target.afterEvaluate { target.forceCompileSdk(36) }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
