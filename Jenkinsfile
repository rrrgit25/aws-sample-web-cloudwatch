// CI pipeline for sample-web (Jenkins multibranch pipeline).
//
//   Pull requests / branches : unit tests, Helm lint, Terraform validate,
//                              shell syntax check, Docker build (no push)
//   main                     : all of the above + push image to ECR and
//                              archive build.properties, which triggers the
//                              Spinnaker "deploy-sample-web" pipeline.
//
// Requirements (see docs/CICD.md):
//   Plugins : Pipeline, Docker Pipeline, GitHub Branch Source, AWS Credentials,
//             JUnit, Timestamper
//   Agents  : any agent with Docker for the containerised stages; an agent
//             labelled "docker" with Docker + AWS CLI v2 for the build stage
//   Credential "aws-ecr-push" (AWS Credentials) for the IAM user created by
//             terraform/ci.tf (create_ci_user = true)

pipeline {
  agent none

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    AWS_REGION         = 'us-east-1'
    ECR_REPOSITORY     = 'sample-web'
    AWS_CREDENTIALS_ID = 'aws-ecr-push'
  }

  stages {
    stage('Unit tests') {
      agent { docker { image 'python:3.12-slim' } }
      environment {
        HOME             = "${WORKSPACE}"
        PIP_NO_CACHE_DIR = '1'
      }
      steps {
        dir('app') {
          sh '''
            python -m venv "$WORKSPACE/.venv"
            "$WORKSPACE/.venv/bin/pip" install -q -r requirements-dev.txt
            "$WORKSPACE/.venv/bin/pytest" -q -p no:cacheprovider --junitxml=test-results.xml
          '''
        }
      }
      post {
        always { junit 'app/test-results.xml' }
      }
    }

    stage('Lint & validate') {
      parallel {
        stage('Helm lint') {
          agent { docker { image 'alpine/helm:3.16.4'; args '--entrypoint=' } }
          environment { HOME = "${WORKSPACE}" }
          steps {
            sh '''
              helm lint helm/sample-web
              helm template sample-web helm/sample-web --set fullnameOverride=sample-web > /dev/null
            '''
          }
        }

        stage('Terraform validate') {
          agent { docker { image 'hashicorp/terraform:1.10.5'; args '--entrypoint=' } }
          environment { HOME = "${WORKSPACE}" }
          steps {
            dir('terraform') {
              sh '''
                terraform fmt -check -recursive
                terraform init -backend=false -input=false
                terraform validate
              '''
            }
          }
        }

        stage('Shell syntax') {
          agent { docker { image 'bash:5.2' } }
          steps {
            sh 'for f in scripts/*.sh; do bash -n "$f"; done'
          }
        }
      }
    }

    stage('Build & push image') {
      agent { label 'docker' }
      steps {
        script {
          env.IMAGE_TAG = "${env.GIT_COMMIT.take(7)}-${env.BUILD_NUMBER}"
        }

        sh 'docker build --platform linux/amd64 -t "sample-web:${IMAGE_TAG}" app'

        script {
          if (env.BRANCH_NAME == 'main') {
            withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS_ID]]) {
              sh '''
                set -eu
                ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
                REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                IMAGE="${REGISTRY}/${ECR_REPOSITORY}"

                aws ecr get-login-password --region "${AWS_REGION}" \
                  | docker login --username AWS --password-stdin "${REGISTRY}"

                docker tag "sample-web:${IMAGE_TAG}" "${IMAGE}:${IMAGE_TAG}"
                docker push "${IMAGE}:${IMAGE_TAG}"

                # Read by Spinnaker's Jenkins trigger (propertyFile).
                cat > build.properties <<EOF
IMAGE_REPOSITORY=${IMAGE}
IMAGE_TAG=${IMAGE_TAG}
GIT_COMMIT=${GIT_COMMIT}
EOF
                cat build.properties
              '''
            }
            archiveArtifacts artifacts: 'build.properties', fingerprint: true
          } else {
            echo "Branch ${env.BRANCH_NAME}: image built but not pushed (only main is pushed)."
          }
        }
      }
      post {
        always {
          sh 'docker image rm "sample-web:${IMAGE_TAG}" >/dev/null 2>&1 || true'
        }
      }
    }
  }
}
