allprojects {
    repositories {
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

// Ensure third-party Flutter Android plugins (e.g. file_picker) meet compileSdk >= 36
// wastePluginCompileSdkAlign
subprojects {
    if (project.name != "app") {
        project.afterEvaluate {
            val androidExt = project.extensions.findByName("android")
            if (androidExt != null) {
                val getSdk = androidExt.javaClass.methods.firstOrNull {
                    it.name == "getCompileSdk" && it.parameterCount == 0
                }
                val currentSdk = (getSdk?.invoke(androidExt) as? Number)?.toInt() ?: 0
                if (currentSdk < 36) {
                    val setSdk = androidExt.javaClass.methods.firstOrNull {
                        (it.name == "setCompileSdk" || it.name == "compileSdkVersion") &&
                            it.parameterCount == 1 &&
                            (it.parameterTypes[0].name == "int" ||
                             it.parameterTypes[0].name == "java.lang.Integer")
                    }
                    setSdk?.invoke(androidExt, 36)
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
