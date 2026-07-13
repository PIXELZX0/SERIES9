// CI/CD for the PIXELZX payment stack (LeoPayGate / UserVirtualWalletManager /
// VirtualWallet) on Monad mainnet.
//
// Every push: forge build + forge test.
// Impl change: UpgradeLeoPayGateStack.s.sol self-detects drift by comparing
// compiled runtime bytecode against the live implementations (no git-diff
// guessing, idempotent), then — after a MANUAL approval gate — deploys the
// changed impls and upgrades the proxies/beacon.
//
// One-time Jenkins setup:
//   1. Credentials → add Secret text, id: monad-owner-private-key
//      (the proxy-owner key; this key can upgrade money contracts — restrict
//      credential to this job and keep the job non-parameterized-by-strangers)
//   2. Pipeline job pointing at this repo, branch main, script path Jenkinsfile.
//   3. Agent needs Foundry (curl -L https://foundry.paradigm.xyz | bash; foundryup).

pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
    }

    environment {
        PATH = "${env.HOME}/.foundry/bin:${env.PATH}"
        MONAD_RPC = 'https://rpc.monad.xyz'
    }

    stages {
        stage('Submodules') {
            steps {
                sh 'git submodule update --init --depth 1'
            }
        }

        stage('Build') {
            steps {
                sh 'forge build'
            }
        }

        stage('Test') {
            steps {
                sh 'forge test'
            }
        }

        stage('Check upgrades') {
            steps {
                script {
                    env.UPGRADES_PENDING = sh(
                        script: "CHECK_ONLY=true forge script script/UpgradeLeoPayGateStack.s.sol --rpc-url ${MONAD_RPC} | tee check.log | grep -o 'UPGRADES_PENDING= *[0-9]*' | grep -o '[0-9]*'",
                        returnStdout: true
                    ).trim()
                    sh 'cat check.log'
                    echo "Pending implementation upgrades: ${env.UPGRADES_PENDING}"
                }
            }
        }

        stage('Approve mainnet upgrade') {
            when {
                expression { env.UPGRADES_PENDING != '0' }
            }
            steps {
                timeout(time: 1, unit: 'DAYS') {
                    input message: "Deploy + upgrade ${env.UPGRADES_PENDING} implementation(s) on Monad MAINNET?",
                          ok: 'Upgrade'
                }
            }
        }

        stage('Deploy & upgrade') {
            when {
                expression { env.UPGRADES_PENDING != '0' }
            }
            steps {
                withCredentials([string(credentialsId: 'monad-owner-private-key', variable: 'PRIVATE_KEY')]) {
                    sh "forge script script/UpgradeLeoPayGateStack.s.sol --rpc-url ${MONAD_RPC} --broadcast"
                }
            }
        }

        stage('Verify') {
            when {
                expression { env.UPGRADES_PENDING != '0' }
            }
            steps {
                script {
                    def remaining = sh(
                        script: "CHECK_ONLY=true forge script script/UpgradeLeoPayGateStack.s.sol --rpc-url ${MONAD_RPC} | grep -o 'UPGRADES_PENDING= *[0-9]*' | grep -o '[0-9]*'",
                        returnStdout: true
                    ).trim()
                    if (remaining != '0') {
                        error("Post-upgrade check still reports ${remaining} pending upgrade(s)")
                    }
                    echo 'All implementations verified up to date on-chain.'
                }
            }
        }
    }
}
