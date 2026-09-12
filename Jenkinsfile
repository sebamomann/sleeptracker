pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        // Rotates Jenkins build records and logs only — Docker images are handled by
        // ci/prune-images.sh from the post block below.
        buildDiscarder(logRotator(numToKeepStr: '7'))
        timeout(time: 30, unit: 'MINUTES')
        ansiColor('xterm')
        timestamps()
    }

    parameters {
        string(
            name: 'IMAGES_TO_KEEP',
            defaultValue: '5',
            description: 'How many recent sleeptracker images to keep for THIS branch after the build. Older ones are removed unless a container still uses them.'
        )
    }

    environment {
        DOCKER_BUILDKIT = '1'
        image_name    = 'sleeptracker'

        // Branch-scoped Docker resource names, as in the plants pipeline. This is a
        // multibranch setup: `disableConcurrentBuilds()` serialises ONE job, but a feature
        // branch and main run simultaneously on the same host, and each multibranch job
        // keeps its own BUILD_NUMBER counter — so the build number alone is not unique
        // across branches. With shared names, whichever build reaches its cleanup first
        // deletes the other's containers mid-run.
        branch_slug   = "${(env.BRANCH_NAME ?: 'default').replaceAll('[^A-Za-z0-9]', '-').toLowerCase().take(24)}"

        // Immutable per-build tag — built, tested and deployed as the same artifact, so the
        // running version is traceable and a previous build can be rolled back to.
        image_ref     = "${image_name}:${branch_slug}-${env.BUILD_NUMBER}"
        app_container = 'sleeptracker-app'
        network_name  = 'sleeptracker-network'
        app_port      = '34257'

        test_container  = "sleeptracker-unit-${branch_slug}"
        smoke_container = "sleeptracker-smoke-${branch_slug}"
    }

    stages {
        stage('Verify & Build') {
            failFast true
            parallel {
                stage('Unit Tests') {
                    steps {
                        script {
                            sh """
                                docker rm -fv ${test_container} || true
                                # The app has no dependencies, so there is no npm ci and no cache
                                # volume to maintain — the runner is a bare node image plus the
                                # tracked sources.
                                docker create \\
                                    --name ${test_container} \\
                                    -w /workspace \\
                                    -e NO_COLOR=1 -e FORCE_COLOR=0 \\
                                    node:24-alpine \\
                                    sh -c 'node --test "tests/*.test.mjs"'
                                # git archive streams tracked files only, so this cannot pick up a
                                # stray node_modules or a local certs/ directory from the agent.
                                git archive --format=tar --prefix=workspace/ HEAD \\
                                    public tests package.json \\
                                    | docker cp - ${test_container}:/
                                docker start -a ${test_container}
                            """
                        }
                    }
                    post {
                        always { sh "docker rm -fv ${test_container} || true" }
                    }
                }

                stage('Build Docker image') {
                    steps {
                        script {
                            def image = docker.build(image_ref)
                            // Convenience moving tag; deploy still pins the immutable ${image_ref}.
                            // Only main moves it: `latest` is a single global name, so a feature
                            // branch tagging it would leave the host's `latest` pointing at
                            // unreviewed code.
                            if (env.BRANCH_NAME == null || env.BRANCH_NAME == 'main') {
                                image.tag('latest')
                            }
                        }
                    }
                }
            }
        }

        stage('Smoke Test') {
            // Proves the image actually serves before it is allowed anywhere near the
            // deploy stage: the app is static, so "it builds" and "it works" are only one
            // COPY path apart, and that path is exactly what breaks silently.
            steps {
                sh """
                    docker rm -fv ${smoke_container} || true
                    docker run -d --name ${smoke_container} ${image_ref}

                    ok=0
                    for i in \$(seq 1 20); do
                        docker exec ${smoke_container} wget -qO- http://127.0.0.1:3000/api/health > /dev/null 2>&1 && { ok=1; break; }
                        sleep 1
                    done
                    if [ "\$ok" != "1" ]; then
                        echo "Health endpoint never came up"
                        docker logs --tail 50 ${smoke_container} || true
                        exit 1
                    fi

                    # The page and its analysis module must both be served — a broken COPY in
                    # the Dockerfile still passes a health check that only touches the server.
                    for path in / /analysis.js /silent-audio.js /manifest.webmanifest; do
                        docker exec ${smoke_container} wget -qO- "http://127.0.0.1:3000\$path" > /dev/null 2>&1 \\
                            || { echo "Missing asset: \$path"; exit 1; }
                    done
                    echo "Smoke test passed"
                """
            }
            post {
                always { sh "docker rm -fv ${smoke_container} || true" }
            }
        }

        stage('Deploy') {
            // Only deploy from main. Classic (single-branch) jobs have no BRANCH_NAME and
            // still deploy; multibranch jobs are guarded against deploying feature branches.
            when {
                expression { env.BRANCH_NAME == null || env.BRANCH_NAME == 'main' }
            }
            steps {
                sh """
                    docker network create ${network_name} || true

                    # Set the running container aside (stopped + renamed) rather than deleting
                    # it, so a failed rollout can be rolled back. Stopping frees the port.
                    docker rm -fv ${app_container}-old || true
                    docker stop ${app_container} || true
                    docker rename ${app_container} ${app_container}-old || true

                    # No volumes: the app is stateless. A night's data lives in the phone's
                    # localStorage until phase 2 adds an upload endpoint.
                    docker run -d \\
                        --name ${app_container} \\
                        --network ${network_name} \\
                        --restart unless-stopped \\
                        -p ${app_port}:3000 \\
                        ${image_ref}

                    deployed=0
                    for i in \$(seq 1 30); do
                        docker exec ${app_container} wget -qO- http://127.0.0.1:3000/api/health > /dev/null 2>&1 && { deployed=1; break; }
                        sleep 2
                    done

                    if [ "\$deployed" != "1" ]; then
                        echo "New container failed health check — rolling back"
                        docker logs --tail 80 ${app_container} || true
                        docker rm -fv ${app_container} || true
                        docker rename ${app_container}-old ${app_container} || true
                        docker start ${app_container} || true
                        exit 1
                    fi

                    echo "Deploy healthy — removing previous container"
                    docker rm -fv ${app_container}-old || true
                """
            }
        }
    }

    post {
        // Single-quoted on purpose: the script reads image_name, branch_slug and
        // IMAGES_TO_KEEP straight from the environment, so nothing is interpolated into a
        // shell string here. catchError so housekeeping never fails an already-deployed build.
        always {
            catchError(buildResult: 'SUCCESS', stageResult: 'SUCCESS') {
                sh 'sh ci/prune-images.sh'
            }
        }
    }
}
