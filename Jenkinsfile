// ---------------------------------------------------------------------------
// System Control Centre — Multibranch Pipeline
//
// Builds autopilot-frontend / autopilot-haskell (linux/amd64, plain `docker
// build` — this Jenkins agent has no buildx plugin) and ships to all four
// registries:
//   AWS Master   (463356420488, beckn-uat)
//   AWS Prod     (147728078333)
//   GCP Master   (ny-sandbox)
//   GCP Prod     (ny-prod)
//
// Tag = short commit hash of whatever branch/commit triggered the build.
//
// frontend/Dockerfile inlines VITE_API_BASE_URL into the JS bundle at build
// time (see its own header comment), so it needs a separate build per
// target. backend/Dockerfile declares no build ARGs — it reads all config
// at runtime — so the same image would work everywhere, but is still built
// per target here to keep this pipeline a straight match for the commands
// this was modeled on.
// ---------------------------------------------------------------------------

def buildAndPushFrontend(String registryTag, String apiBaseUrl) {
  sh "docker build --platform=linux/amd64" +
     " --build-arg VITE_API_BASE_URL=${apiBaseUrl}" +
     " -t ${registryTag} ./frontend"
  sh "docker push ${registryTag}"
}

def buildAndPushBackend(String registryTag) {
  sh "docker build --platform=linux/amd64 -t ${registryTag} ./backend"
  sh "docker push ${registryTag}"
}

def ecrLogin(String accountId, String region) {
  sh "aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin ${accountId}.dkr.ecr.${region}.amazonaws.com"
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

pipeline {
  parameters {
    choice(name: 'app', choices: ['autopilot-backend', 'autopilot-frontend'], description: 'Which app to build')
  }

  agent {
    kubernetes {
      label 'dind-agent'
    }
  }

  environment {
    AWS_REGION = 'ap-south-1'

    // AWS Master / beckn-uat
    AWS_ACCOUNT_MASTER = '463356420488'
    API_URL_AWS_MASTER  = 'https://namma-ap.sso.integ.internal.svc.movingtech.net/api'

    // AWS Production
    AWS_ACCOUNT_PROD = '147728078333'
    API_URL_AWS_PROD = 'https://namma-ap.sso.internal.svc.movingtech.net/api'

    // GCP Master (ny-sandbox)
    GCP_PROJECT_MASTER = 'ny-sandbox'
    GCP_AR_MASTER       = "asia-south1-docker.pkg.dev/${GCP_PROJECT_MASTER}"
    API_URL_GCP_MASTER  = 'https://namma-ap.sso.c2.integ.internal.svc.movingtech.net/api'

    // GCP Production (ny-prod)
    GCP_PROJECT_PROD = 'ny-prod'
    GCP_AR_PROD       = "asia-south1-docker.pkg.dev/${GCP_PROJECT_PROD}"
    API_URL_GCP_PROD  = 'https://namma-ap.c2.sso.internal.svc.movingtech.net/api'
  }

  stages {

    stage('Initialize') {
      steps {
        script {
          env.TAG = sh(script: 'git rev-parse HEAD', returnStdout: true).trim().substring(0, 7)
          echo "Building ${params.app} @ ${env.TAG}"
        }
      }
    }

    stage('Deploy to AWS Master (4633...)') {
      steps {
        script {
          ecrLogin(env.AWS_ACCOUNT_MASTER, env.AWS_REGION)
          if (params.app == 'autopilot-frontend') {
            buildAndPushFrontend("${env.AWS_ACCOUNT_MASTER}.dkr.ecr.${env.AWS_REGION}.amazonaws.com/autopilot-frontend:${env.TAG}", env.API_URL_AWS_MASTER)
          } else {
            buildAndPushBackend("${env.AWS_ACCOUNT_MASTER}.dkr.ecr.${env.AWS_REGION}.amazonaws.com/autopilot-haskell:${env.TAG}")
          }
        }
      }
    }

    stage('Deploy to AWS Production (1477...)') {
      steps {
        script {
          ecrLogin(env.AWS_ACCOUNT_PROD, env.AWS_REGION)
          if (params.app == 'autopilot-frontend') {
            buildAndPushFrontend("${env.AWS_ACCOUNT_PROD}.dkr.ecr.${env.AWS_REGION}.amazonaws.com/autopilot-frontend:${env.TAG}", env.API_URL_AWS_PROD)
          } else {
            buildAndPushBackend("${env.AWS_ACCOUNT_PROD}.dkr.ecr.${env.AWS_REGION}.amazonaws.com/autopilot-haskell:${env.TAG}")
          }
        }
      }
    }

    stage('Deploy to GCP Master') {
      steps {
        withCredentials([file(credentialsId: 'gcp-sa-key', variable: 'GCP_KEY_FILE')]) {
          script {
            sh 'cat $GCP_KEY_FILE | docker login -u _json_key --password-stdin https://asia-south1-docker.pkg.dev'
            if (params.app == 'autopilot-frontend') {
              buildAndPushFrontend("${env.GCP_AR_MASTER}/autopilot-frontend/autopilot-frontend:${env.TAG}", env.API_URL_GCP_MASTER)
            } else {
              buildAndPushBackend("${env.GCP_AR_MASTER}/autopilot-haskell/autopilot-haskell:${env.TAG}")
            }
          }
        }
      }
    }

    stage('Deploy to GCP Production') {
      steps {
        withCredentials([file(credentialsId: 'gcp-sa-key-prod', variable: 'GCP_KEY_FILE_PROD')]) {
          script {
            sh 'cat $GCP_KEY_FILE_PROD | docker login -u _json_key --password-stdin https://asia-south1-docker.pkg.dev'
            if (params.app == 'autopilot-frontend') {
              buildAndPushFrontend("${env.GCP_AR_PROD}/autopilot-frontend/autopilot-frontend:${env.TAG}", env.API_URL_GCP_PROD)
            } else {
              buildAndPushBackend("${env.GCP_AR_PROD}/autopilot-haskell/autopilot-haskell:${env.TAG}")
            }
          }
        }
      }
    }
  }
}
