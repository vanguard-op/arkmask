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
    // Force every plugin subproject to compile against API 36 so that
    // flutter_plugin_android_lifecycle (required by file_picker 8.x) resolves.
    afterEvaluate {
        if (project.hasProperty("android")) {
            (project.extensions.findByName("android")
                as? com.android.build.gradle.BaseExtension)
                ?.compileSdkVersion(36)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
