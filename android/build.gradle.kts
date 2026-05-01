// Top-level build file for VPN+TOR Android project.
buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Clean task.
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
