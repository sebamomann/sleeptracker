pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '7'))
        timeout(time: 15, unit: 'MINUTES')
        ansiColor('xterm')
        timestamps()
    }

    // The checks that run on Linux. The app has nothing to deploy — it lives on the phone —
    // and its tests need Xcode and a simulator, so `make test` runs them on the Mac.
    environment {
        branch_slug    = "${(env.BRANCH_NAME ?: 'default').replaceAll('[^A-Za-z0-9]', '-').toLowerCase().take(24)}"
        lint_container = "sleeptracker-lint-${branch_slug}"
    }

    stages {
        stage('Verify') {
            failFast true
            parallel {
                stage('Lint') {
                    steps {
                        script {
                            sh """
                                docker rm -fv ${lint_container} || true
                                # --strict turns warnings into failures. The thresholds in
                                # .swiftlint.yml are set where the code already sits, so a
                                # violation means something changed, not that the bar was
                                # never met — which is what makes failing the build fair.
                                docker create \\
                                    --name ${lint_container} \\
                                    -w /workspace \\
                                    -e NO_COLOR=1 \\
                                    ghcr.io/realm/swiftlint:0.65.1 \\
                                    swiftlint lint --strict --quiet
                                # git archive streams tracked files only.
                                git archive --format=tar --prefix=workspace/ HEAD \\
                                    ios/SleepTracker ios/SleepTrackerTests ios/SleepTrackerUITests .swiftlint.yml \\
                                    | docker cp - ${lint_container}:/
                                docker start -a ${lint_container}
                            """
                        }
                    }
                    post {
                        always { sh "docker rm -fv ${lint_container} || true" }
                    }
                }

                stage('Duplication') {
                    steps {
                        script {
                            sh """
                                docker rm -fv ${lint_container}-dup || true
                                # jscpd needs `format` to include swift explicitly — it is not
                                # in the default set, and without it the whole app is silently
                                # skipped while the report still reads 0 clones.
                                docker create \\
                                    --name ${lint_container}-dup \\
                                    -w /workspace \\
                                    -e NO_COLOR=1 \\
                                    node:24-alpine \\
                                    npx --yes jscpd@4 . --config .jscpd.json --reporters console
                                git archive --format=tar --prefix=workspace/ HEAD \\
                                    ios/SleepTracker ios/SleepTrackerTests ios/SleepTrackerUITests .jscpd.json \\
                                    | docker cp - ${lint_container}-dup:/
                                docker start -a ${lint_container}-dup
                            """
                        }
                    }
                    post {
                        always { sh "docker rm -fv ${lint_container}-dup || true" }
                    }
                }
            }
        }
    }
}
